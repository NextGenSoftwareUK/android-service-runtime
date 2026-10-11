import Foundation
import Security

// iOS counterpart of HolochainUnityBridge.kt: runs the Holochain 0.7 conductor in-process (wasmi interpreter
// build from HolochainConductor.xcframework) and exposes a C ABI for Unity's [DllImport("__Internal")].
//
// Every call is asynchronous: the caller passes a request id and a callback, which is invoked exactly once.
// Byte arrays cross the boundary as base64 strings, like the Android bridge. iOS has no long-lived
// background service, so the conductor only runs while the app is active; Unity drives suspend/resume.

public typealias HoloSessionCallback = @convention(c) (
    Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias HoloOperationCallback = @convention(c) (
    Int32, Bool, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
public typealias HoloSignCallback = @convention(c) (
    Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

private actor ConductorHolder {
    var runtime: RuntimeFfi?

    func set(_ value: RuntimeFfi?) { runtime = value }
}

private let holder = ConductorHolder()

/// Source of the keystore passphrase; tests replace it because hostless test bundles may lack Keychain access.
var passphraseProvider: () throws -> Data = keystorePassphrase

/// The running conductor, for tests.
func currentRuntime() async throws -> RuntimeFfi {
    guard let runtime = await holder.runtime else {
        throw NSError(domain: "HolochainUnityBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "not started"])
    }
    return runtime
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer = pointer else { return nil }
    return String(cString: pointer)
}

private func decode(_ pointer: UnsafePointer<CChar>?) -> Data {
    Data(base64Encoded: string(pointer) ?? "") ?? Data()
}

private func describe(_ error: Error) -> String { String(describing: error) }

/// The conductor passphrase protects the lair keystore. One random secret per install, kept in the Keychain.
private func keystorePassphrase() throws -> Data {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "one.oasisomniverse.holochain",
        kSecAttrAccount as String: "lair-passphrase",
    ]
    var found: AnyObject?
    if SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &found) == errSecSuccess,
       let data = found as? Data {
        return data
    }
    var secret = Data(count: 32)
    let status = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    guard status == errSecSuccess else { throw NSError(domain: "HolochainUnityBridge", code: Int(status)) }
    var add = query
    add[kSecValueData as String] = secret
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw NSError(domain: "HolochainUnityBridge", code: Int(added)) }
    return secret
}

private func dataRoot() throws -> String {
    let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: true)
    let root = base.appendingPathComponent("holochain", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableRoot = root
    try? mutableRoot.setResourceValues(values)
    return root.path
}

private func reportSession(_ callback: HoloSessionCallback, _ requestId: Int32, _ auth: AppAuthFfi) {
    auth.authentication.token.base64EncodedString().withCString { token in
        callback(requestId, Int32(auth.port), token, nil, nil)
    }
}

private func reportSessionError(_ callback: HoloSessionCallback, _ requestId: Int32, _ code: String, _ message: String) {
    code.withCString { c in message.withCString { m in callback(requestId, 0, nil, c, m) } }
}

private func reportOperation(_ callback: HoloOperationCallback, _ requestId: Int32, _ error: (String, String)?) {
    guard let (code, message) = error else { callback(requestId, true, nil, nil); return }
    code.withCString { c in message.withCString { m in callback(requestId, false, c, m) } }
}

/// Starts the conductor (if needed), installs/enables the hApp and returns its app-websocket port and token.
@_cdecl("holo_ios_start_and_setup")
public func holo_ios_start_and_setup(
    _ requestId: Int32,
    _ appBundle: UnsafePointer<UInt8>?, _ appBundleLength: Int32,
    _ installedAppId: UnsafePointer<CChar>?, _ networkSeed: UnsafePointer<CChar>?,
    _ bootstrapUrl: UnsafePointer<CChar>?, _ relayUrl: UnsafePointer<CChar>?,
    _ callback: HoloSessionCallback
) {
    guard let appBundle = appBundle, appBundleLength > 0, let appId = string(installedAppId) else {
        reportSessionError(callback, requestId, "HOLO_IOS_ARGUMENTS_INVALID", "The hApp bundle and app id are required.")
        return
    }
    let bundle = Data(bytes: appBundle, count: Int(appBundleLength))
    let seed = string(networkSeed)
    let bootstrap = string(bootstrapUrl) ?? ""
    let relay = string(relayUrl) ?? ""
    Task.detached {
        if await holder.runtime != nil {
            reportSessionError(callback, requestId, "HOLO_IOS_ALREADY_STARTED", "The Holochain conductor is already running.")
            return
        }
        let runtime: RuntimeFfi
        do {
            runtime = try await RuntimeFfi.start(
                passphrase: try passphraseProvider(),
                runtimeConfig: RuntimeConfigFfi(
                    dataRootPath: try dataRoot(),
                    network: RuntimeNetworkConfigFfi(bootstrapUrl: bootstrap, relayUrl: relay)))
        } catch {
            reportSessionError(callback, requestId, "HOLO_IOS_CONDUCTOR_START_FAILED", describe(error))
            return
        }
        await holder.set(runtime)
        do {
            let auth = try await runtime.setupApp(
                payload: InstallAppPayloadFfi(source: bundle, installedAppId: appId, networkSeed: seed,
                                              rolesSettings: nil, agentKey: nil),
                enableAfterInstall: true)
            reportSession(callback, requestId, auth)
        } catch {
            reportSessionError(callback, requestId, "HOLO_IOS_APP_SETUP_FAILED", describe(error))
        }
    }
}

/// Returns a fresh app-websocket port and token for an installed app (after the app returns to the foreground).
@_cdecl("holo_ios_resume")
public func holo_ios_resume(_ requestId: Int32, _ installedAppId: UnsafePointer<CChar>?, _ callback: HoloSessionCallback) {
    let appId = string(installedAppId) ?? ""
    Task.detached {
        guard let runtime = await holder.runtime else {
            reportSessionError(callback, requestId, "HOLO_IOS_NOT_STARTED", "The Holochain conductor is not running.")
            return
        }
        do {
            reportSession(callback, requestId, try await runtime.ensureAppWebsocket(installedAppId: appId))
        } catch {
            reportSessionError(callback, requestId, "HOLO_IOS_RESUME_FAILED", describe(error))
        }
    }
}

/// Signs a zome call with the agent key held by the conductor's keystore.
@_cdecl("holo_ios_sign_zome_call")
public func holo_ios_sign_zome_call(
    _ requestId: Int32,
    _ provenance: UnsafePointer<CChar>?, _ dnaHash: UnsafePointer<CChar>?, _ agentPubKey: UnsafePointer<CChar>?,
    _ zomeName: UnsafePointer<CChar>?, _ fnName: UnsafePointer<CChar>?, _ capSecret: UnsafePointer<CChar>?,
    _ payload: UnsafePointer<CChar>?, _ nonce: UnsafePointer<CChar>?, _ expiresAt: Int64,
    _ callback: HoloSignCallback
) {
    let secret = decode(capSecret)
    let params = ZomeCallParamsFfi(
        provenance: decode(provenance),
        cellId: CellIdFfi(dnaHash: decode(dnaHash), agentPubKey: decode(agentPubKey)),
        zomeName: string(zomeName) ?? "", fnName: string(fnName) ?? "",
        capSecret: secret.isEmpty ? nil : secret,
        payload: decode(payload), nonce: decode(nonce), expiresAt: expiresAt)
    Task.detached {
        guard let runtime = await holder.runtime else {
            "HOLO_IOS_NOT_STARTED".withCString { c in "The Holochain conductor is not running.".withCString { m in
                callback(requestId, nil, nil, c, m) } }
            return
        }
        do {
            let signed = try await runtime.signZomeCall(zomeCallUnsigned: params)
            signed.bytes.base64EncodedString().withCString { b in
                signed.signature.base64EncodedString().withCString { s in callback(requestId, b, s, nil, nil) } }
        } catch {
            "HOLO_IOS_SIGN_FAILED".withCString { c in describe(error).withCString { m in callback(requestId, nil, nil, c, m) } }
        }
    }
}

/// Shuts the conductor down (on app exit, or when iOS is about to suspend the app).
@_cdecl("holo_ios_stop")
public func holo_ios_stop(_ requestId: Int32, _ callback: HoloOperationCallback) {
    Task.detached {
        guard let runtime = await holder.runtime else { reportOperation(callback, requestId, nil); return }
        do {
            try await runtime.stop()
            await holder.set(nil)
            reportOperation(callback, requestId, nil)
        } catch {
            reportOperation(callback, requestId, ("HOLO_IOS_STOP_FAILED", describe(error)))
        }
    }
}
