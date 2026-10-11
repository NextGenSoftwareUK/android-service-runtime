// swift-tools-version:5.9
// Swift wrapper for the Holochain 0.7 conductor (wasmi interpreter build) on iOS.
// CI copies HolochainConductor.xcframework and the generated UniFFI Swift files in before building;
// see .github/workflows/ios-conductor.yml.
import PackageDescription

let package = Package(
    name: "HolochainConductor",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "HolochainConductor", targets: ["HolochainConductor"]),
    ],
    targets: [
        .binaryTarget(name: "HolochainConductorFFI", path: "HolochainConductor.xcframework"),
        .target(
            name: "HolochainConductor",
            dependencies: ["HolochainConductorFFI"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                // iroh watches network changes through Network.framework (nw_path_monitor_*).
                .linkedFramework("Network"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(
            name: "HolochainConductorTests",
            dependencies: ["HolochainConductor"],
            resources: [.copy("Resources/oasis.happ")]
        ),
    ]
)
