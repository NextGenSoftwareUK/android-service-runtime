Everything you need to run Holochain 0.7 on **Android and iOS**, in one place: the runtime apps, the libraries an app compiles in, and the iOS conductor and bridge. Built from the [`oasis/holochain-0.7`](https://github.com/NextGenSoftwareUK/android-service-runtime/tree/oasis/holochain-0.7) branch of this fork of [holochain/android-service-runtime](https://github.com/holochain/android-service-runtime). It is what Our World (the OASIS Edge runtime) and the HoloNET `dotnet new` templates use.

> **Status: pre-release.** Android is proven on an x86_64 emulator and the iOS conductor on the iOS simulator (OASIS CI). **Nothing here has been run on a physical phone yet**, and the iOS bridge has not been linked into a .NET app by us. Please test and tell us what you find.

## Which file do I need?

| I want to... | Download |
|---|---|
| Try Holochain on an Android phone or emulator (install the shared runtime app) | `android-service-runtime-0.2.0-holochain-0.7-arm64-debug.apk` (phones) or `...-x86_64-debug.apk` (emulators) |
| Build an Android app that uses the runtime, or has its own conductor built in | `holochain-client.aar`, `holochain-service.aar`, `holonet-android-bridge.aar` and `holochain-android-dependencies.zip` (the HoloNET templates download these for you) |
| Build an iOS app in .NET (HoloNET templates, MAUI, Uno) | `HoloNETIosBridge.xcframework.zip` |
| Build an iOS app in Swift or Unity | `HolochainConductor.xcframework.zip` and `HolochainConductorSwift.zip` |
| Check a download | `SHA256SUMS.txt`, `android-build-manifest.json`, `ios-build-manifest.json` |

## Android

- **The runtime app (APKs).** The **Holochain Service Runtime**: one shared conductor on the phone that every Holochain app uses. A user approves each app once, in a notification. Debug-signed, Holochain 0.7. `arm64` is for phones, `x86_64` for emulators.
- **The libraries (AARs).**
  - `holochain-client.aar` talks to the shared runtime app.
  - `holochain-service.aar` is the conductor itself (arm64 only, about 100 MB unpacked), used for the built-in conductor when the phone has no shared runtime.
  - `holonet-android-bridge.aar` is the Kotlin bridge: it picks the shared runtime first and falls back to the built-in conductor, and signs zome calls.
  - `holochain-android-dependencies.zip` holds the bridge's runtime dependencies. Apps that already bring AndroidX and Kotlin (MAUI, Uno) only need the Holochain libraries and JNA from it.
  - They need Android 8.1 (API 27) or newer.

## iOS

- **`HoloNETIosBridge.xcframework.zip`** (for .NET apps): the `holo_ios_*` C interface plus the conductor, for device and Apple-silicon simulator. Link it as a `NativeReference` and call it with P/Invoke.
- **`HolochainConductor.xcframework.zip` + `HolochainConductorSwift.zip`** (for Swift and Unity): the conductor static libraries with the UniFFI Swift bindings and the Swift bridge source. Built with the wasmi interpreter, because iOS forbids JIT. Minimum iOS 15.

## What is proven

| Piece | Proven | Not yet |
|---|---|---|
| Android shared runtime and built-in fallback | x86_64 emulator (OASIS device test) | a physical phone |
| HoloNET Android templates | build with these libraries; the APK contains the conductor | running on a device or emulator |
| iOS conductor | iOS simulator (start, install the OASIS hApp, signed zome call) | a physical iPhone |
| iOS bridge for .NET | symbols confirmed in the library | linking it into a .NET app on a Mac |

## Where this fits

- **HoloNET templates and docs:** [docs.holonet.oasisomniverse.one/templates](https://docs.holonet.oasisomniverse.one/templates)
- **OASIS Edge runtime and game clients** (what Our World uses): [NextGenSoftwareUK/OASIS releases](https://github.com/NextGenSoftwareUK/OASIS/releases): [Edge Runtime](https://github.com/NextGenSoftwareUK/OASIS/releases/tag/OASIS-Edge-Runtime-v1.2.0), [OGEngineClient + Edge](https://github.com/NextGenSoftwareUK/OASIS/releases/tag/OGEngineClient-Edge-v2.1.0), [OGEngineClient + Edge + Unity](https://github.com/NextGenSoftwareUK/OASIS/releases/tag/OASIS-Edge-Unity-v1.1.0), [OGEngineClient RemoteOnly](https://github.com/NextGenSoftwareUK/OASIS/releases/tag/OGEngineClient-RemoteOnly-v2.1.0).
- **Earlier per-piece releases** (superseded by this one, kept for history): `oasis-holochain-0.7-v1.0.0`, `oasis-runtime-v0.2.0-holochain-0.7`, `oasis-android-libs-v1.0.0`, `oasis-ios-conductor-v0.1.1`, `oasis-ios-bridge-v1.0.0`. The stable iOS conductor `oasis-ios-conductor-v0.7.1` is the same conductor included here.
