import Foundation
import XCTest
@testable import HolochainConductor

/// Exercises the C ABI that Unity calls through [DllImport("__Internal")]: start/setup, resume, sign, stop.
final class UnityBridgeAbiTests: XCTestCase {
    // C callbacks can't capture context, so results go through statics keyed by request id.
    private static var sessions: [Int32: CheckedContinuation<(Int32, String?, String?), Never>] = [:]
    private static var signs: [Int32: CheckedContinuation<(String?, String?, String?), Never>] = [:]
    private static var operations: [Int32: CheckedContinuation<String?, Never>] = [:]
    private static let lock = NSLock()

    private static let onSession: HoloSessionCallback = { id, port, token, code, message in
        lock.lock(); let c = sessions.removeValue(forKey: id); lock.unlock()
        let error = code.map { "\(String(cString: $0)): \(message.map { String(cString: $0) } ?? "")" }
        c?.resume(returning: (port, token.map { String(cString: $0) }, error))
    }
    private static let onSign: HoloSignCallback = { id, bytes, signature, code, message in
        lock.lock(); let c = signs.removeValue(forKey: id); lock.unlock()
        let error = code.map { "\(String(cString: $0)): \(message.map { String(cString: $0) } ?? "")" }
        c?.resume(returning: (bytes.map { String(cString: $0) }, signature.map { String(cString: $0) }, error))
    }
    private static let onOperation: HoloOperationCallback = { id, ok, code, message in
        lock.lock(); let c = operations.removeValue(forKey: id); lock.unlock()
        c?.resume(returning: ok ? nil : "\(code.map { String(cString: $0) } ?? ""): \(message.map { String(cString: $0) } ?? "")")
    }

    private func session(_ id: Int32, _ call: () -> Void) async -> (Int32, String?, String?) {
        await withCheckedContinuation { c in Self.lock.lock(); Self.sessions[id] = c; Self.lock.unlock(); call() }
    }

    func testStartResumeSignStopThroughTheCAbi() async throws {
        passphraseProvider = { Data("ios-abi-test".utf8) }
        let happ = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "oasis", withExtension: "happ")))
        let appId = "oasis-ios-abi"

        let (port, token, error) = await session(1) {
            happ.withUnsafeBytes { raw in
                holo_ios_start_and_setup(1, raw.bindMemory(to: UInt8.self).baseAddress, Int32(happ.count),
                                         appId, UUID().uuidString,
                                         "https://dev-test-bootstrap2.holochain.org",
                                         "https://use1-1.relay.n0.iroh-canary.iroh.link./", Self.onSession)
            }
        }
        XCTAssertNil(error)
        XCTAssertGreaterThan(port, 0)
        XCTAssertFalse((token ?? "").isEmpty)

        // A second start is rejected while the conductor runs.
        let (_, _, again) = await session(2) {
            holo_ios_start_and_setup(2, [1], 1, appId, nil, "https://a.example", "https://b.example", Self.onSession)
        }
        XCTAssertTrue((again ?? "").hasPrefix("HOLO_IOS_ALREADY_STARTED"))

        let (resumedPort, _, resumeError) = await session(3) { holo_ios_resume(3, appId, Self.onSession) }
        XCTAssertNil(resumeError)
        XCTAssertGreaterThan(resumedPort, 0)

        // Sign through the C ABI with this install's agent key.
        let runtime = try await currentRuntime()
        let app = try XCTUnwrap(try await runtime.listApps().first { $0.installedAppId == appId })
        var cellId: CellIdFfi?
        for cells in app.cellInfo.values { for cell in cells { if case .provisioned(let p) = cell { cellId = p.cellId } } }
        let cell = try XCTUnwrap(cellId)
        let b64 = { (d: Data) in d.base64EncodedString() }
        let (bytes, signature, signError) = await withCheckedContinuation { c in
            Self.lock.lock(); Self.signs[4] = c; Self.lock.unlock()
            holo_ios_sign_zome_call(4, b64(cell.agentPubKey), b64(cell.dnaHash), b64(cell.agentPubKey),
                                    "oasis", "get_all_avatars", "", b64(Data([0xc0])), b64(Data(count: 32)),
                                    Int64((Date().timeIntervalSince1970 + 300) * 1_000_000), Self.onSign)
        }
        XCTAssertNil(signError)
        XCTAssertFalse((bytes ?? "").isEmpty)
        XCTAssertEqual(Data(base64Encoded: signature ?? "")?.count, 64)

        let stopError = await withCheckedContinuation { c in
            Self.lock.lock(); Self.operations[5] = c; Self.lock.unlock()
            holo_ios_stop(5, Self.onOperation)
        }
        XCTAssertNil(stopError)
    }
}
