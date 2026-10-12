# OASIS builds: Holochain 0.7 on Android and iOS

This fork (`NextGenSoftwareUK/android-service-runtime`) carries the OASIS changes on the
**`oasis/holochain-0.7`** branch. It tracks upstream
[holochain/android-service-runtime](https://github.com/holochain/android-service-runtime) and adds what
OASIS (the Our World Unity client) needs to run a Holochain **0.7** conductor on **Android and iOS**.

Upstream fixes are offered back as pull requests; see [Upstream status](#upstream-status).

## What the branch changes

| Change | Why | Upstream |
|---|---|---|
| Client parcelers aligned with the 0.7 FFI types | Kotlin client (de)serialisation broke against 0.7 | [#149](https://github.com/holochain/android-service-runtime/pull/149) |
| Tauri service plugin network config = `bootstrapUrl` + `relayUrl` | 0.7 replaced WebRTC (signal + ICE) with iroh; the plugin no longer compiled | [#150](https://github.com/holochain/android-service-runtime/pull/150) |
| Kotlin 1.6-compatible client/service libraries | Unity 2022.3's Gradle toolchain is pinned to Kotlin 1.6 | OASIS-only |
| `wasm-jit` / `wasm-interpreter` features on the runtime crates | iOS forbids JIT; Holochain 0.7's `wasmer-wasmi` interpreter runs zome WASM without it | to offer |
| `ios-conductor` workflow + `ios/HolochainConductor` Swift package | Builds, tests and packages the iOS conductor on macOS CI | to offer (minus the Unity bridge) |
| `ios/.../HolochainUnityBridge.swift` | C ABI for Unity's `[DllImport("__Internal")]` | OASIS-only |
| `crates/runtime/src/ios_lair.rs` | iOS container paths exceed the 104-byte domain-socket limit; lair's socket moves to a short path | to offer |

Android keeps Holochain's default engine (Cranelift JIT). Only iOS builds use the interpreter.

## Android: the shared runtime app

The **Holochain Service Runtime** app (`org.holochain.androidserviceruntime.app`) runs one conductor for every
hApp on the phone. OASIS's Unity bridge prefers it when installed and falls back to its own embedded conductor.

### Build (Windows + WSL, as used for the OASIS release)

Requirements: WSL Ubuntu with Nix (flakes enabled). The repo's `flake.nix` provides the exact Rust toolchain,
Android SDK/NDK, Java and pnpm, so nothing else needs installing.

```bash
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
cd /mnt/c/Source/android-service-runtime
export CARGO_BUILD_JOBS=8
NIX="nix develop --no-update-lock-file --accept-flake-config"
$NIX --command bash -c "pnpm install && pnpm run build:tauri-plugin-client && pnpm run build:tauri-plugin-service"
$NIX --command bash -c "pnpm run build:android-service-runtime --debug --apk --split-per-abi --target aarch64"
$NIX --command bash -c "pnpm run build:android-service-runtime --debug --apk --split-per-abi --target x86_64"
```

APKs land in `apps/android-service-runtime/src-tauri/gen/android/app/build/outputs/apk/<abi>/debug/`.

Gotchas we hit, and the fixes:

- **Windows line endings.** A Windows checkout (`core.autocrlf=true`) gives shell scripts, `gradlew` and
  `flake.nix` CRLF endings, which bash can't run (`$'\r': command not found`, or a stray `\r` in
  `ANDROID_NDK_HOME`). Convert them in place before building; git treats them as unchanged:
  ```bash
  { git ls-files "*.nix" flake.lock; git ls-files | while read f; do [ -f "$f" ] && head -c2 "$f" | grep -q '#!' && echo "$f"; done; } \
    | sort -u | xargs sed -i 's/\r$//'
  ```
- **Out of memory.** Cargo defaults to one job per core; 32 jobs on 15 GB through WSL's `/mnt/c` failed with
  `Cannot allocate memory`. `CARGO_BUILD_JOBS=8` fixes it.
- **Signing.** `app/build.gradle.kts` always loads `gen/android/key.properties`, which holds the upstream
  release key (a CI secret we don't have). For test builds, point it at a standard Android debug keystore
  (`keyAlias=androiddebugkey`, passwords `android`). The file is git-ignored.
- **Disk.** A full build needs tens of GB. Afterwards, `git clean -fdX` (ignored files only: `target/`, Gradle
  output, `node_modules`, `key.properties`) and `nix-collect-garbage -d` reclaim it.

Debug-signed APKs can't upgrade the official app (different signature): uninstall it first.

## iOS: the in-process conductor

iOS can't run a background service or a JIT, so the conductor is a static library linked into the app and
started in-process, using the wasmi interpreter.

### Workflow: `.github/workflows/ios-conductor.yml`

Runs on `macos-15`. Push a tag `oasis-ios-conductor-vX.Y.Z` (manual runs need the workflow on the default branch).

1. Builds `holochain-conductor-runtime-ffi` with `--no-default-features --features wasm-interpreter` for
   `aarch64-apple-ios` (devices) and `aarch64-apple-ios-sim` (Apple-silicon simulator), with
   `IPHONEOS_DEPLOYMENT_TARGET=15.0` (without it, C dependencies target the SDK's iOS 18.5 and linking fails on
   `___chkstk_darwin`).
2. Generates UniFFI Swift bindings.
3. Packages `HolochainConductor.xcframework`.
4. Runs the simulator tests in `ios/HolochainConductor` (below). A failing test stops the release.
5. Writes `build-manifest.json` (commit, Holochain 0.7, wasmi, targets, SHA-256s) and attaches everything to the
   tag's GitHub release.

### Release assets

| File | Contents |
|---|---|
| `HolochainConductor.xcframework.zip` | Static conductor library: device + simulator slices, C headers, module map |
| `HolochainConductorSwift.zip` | UniFFI Swift bindings + `HolochainUnityBridge.swift` (compile them into one module) |
| `build-manifest.json` | Source commit, `holochainCompatibility: "0.7"`, `wasmEngine`, targets, SHA-256 of both zips |

### Tests (`ios/HolochainConductor`)

A Swift package wrapping the xcframework and bindings (CI copies them in; they aren't committed).

- `ConductorSmokeTests`: starts the conductor, installs the OASIS hApp, has the conductor sign
  `oasis.get_all_avatars`, sends `call_zome` over the app websocket and expects `zome_called`.
- `UnityBridgeAbiTests`: the same through the C functions Unity calls (start/setup, duplicate-start rejection,
  resume, sign, stop).

### Unity bridge C ABI (`HolochainUnityBridge.swift`)

All calls are asynchronous: pass a request id and a C callback, invoked exactly once. Byte arrays are base64.

| Function | Result |
|---|---|
| `holo_ios_start_and_setup(id, bundle, len, appId, networkSeed, bootstrapUrl, relayUrl, cb)` | port + app token, or error |
| `holo_ios_resume(id, appId, cb)` | fresh port + token (`ensure_app_websocket`) |
| `holo_ios_sign_zome_call(id, provenance, dna, agent, zome, fn, capSecret, payload, nonce, expiresAt, cb)` | signed bytes + 64-byte signature |
| `holo_ios_stop(id, cb)` | ok or error |

**Link these system frameworks/libraries** into the app (Unity: the UnityFramework target): `Security`,
`SystemConfiguration`, `CoreFoundation`, `Network` (iroh uses `nw_path_monitor_*`) and `libresolv`.

The keystore passphrase is a random 32-byte secret per install in the Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Data lives in Application Support/holochain,
excluded from backup.

## Releases

| Tag | What |
|---|---|
| `oasis-runtime-v0.2.0-holochain-0.7` | Android shared runtime APKs (arm64, x86_64), debug-signed |
| `oasis-ios-conductor-vX.Y.Z` | iOS conductor (workflow output) |
| `oasis-holochain-0.7-vX.Y.Z` | Combined Android + iOS release for OASIS. First: [`oasis-holochain-0.7-v1.0.0`](https://github.com/NextGenSoftwareUK/android-service-runtime/releases/tag/oasis-holochain-0.7-v1.0.0) |

The OASIS repo pins what it consumes: `Scripts/holochain_android_runtime.version.json` (branch commit for the
embedded Android libraries) and `Scripts/holochain_ios_runtime.version.json` (iOS release tag, commit, SHA-256s).

## Upstream status

- [#149](https://github.com/holochain/android-service-runtime/pull/149): client parcelers for the 0.7 FFI types.
- [#150](https://github.com/holochain/android-service-runtime/pull/150): Tauri service plugin network config.
- iOS support (interpreter feature, lair socket fix, macOS workflow, Swift simulator smoke test): proven on the simulator; offered upstream: [#151](https://github.com/holochain/android-service-runtime/pull/151).
