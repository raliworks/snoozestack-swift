// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "snoozestack-swift",
    // No third-party dependencies in any target as of 1.0 (#209); the floors
    // below are what the SDK's own async/Sendable use needs.
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // Full client: application identity + functions + signals + push.
        .library(name: "Shovelbase", targets: ["Shovelbase"]),
        // Signals (event tracking) only — no third-party dependencies.
        .library(name: "ShovelbaseSignals", targets: ["ShovelbaseSignals"]),
        // Deprecated alias of ShovelbaseSignals — kept for existing importers.
        .library(name: "ShovelbaseAnalytics", targets: ["ShovelbaseAnalytics"]),
        // Push notification registration only — no third-party dependencies.
        .library(name: "ShovelbasePush", targets: ["ShovelbasePush"]),
        // snoozestack-named faces of the same modules (the product rename).
        // The Snoozestack* names above stay for existing importers.
        .library(name: "Snoozestack", targets: ["Snoozestack"]),
        .library(name: "SnoozestackSignals", targets: ["SnoozestackSignals"]),
        .library(name: "SnoozestackPush", targets: ["SnoozestackPush"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Shovelbase",
            dependencies: [
                "ShovelbaseSignals",
                "ShovelbasePush",
            ],
            path: "Sources/Shovelbase"
        ),
        .target(name: "ShovelbaseSignals", path: "Sources/ShovelbaseSignals"),
        // Thin re-export of ShovelbaseSignals; keeps `import ShovelbaseAnalytics`
        // working after the rename.
        .target(
            name: "ShovelbaseAnalytics",
            dependencies: ["ShovelbaseSignals"],
            path: "Sources/ShovelbaseAnalytics"
        ),
        .target(name: "ShovelbasePush", path: "Sources/ShovelbasePush"),
        // Thin re-exports under the post-rename names (same pattern as
        // ShovelbaseAnalytics below-left for the Signals rename).
        .target(name: "Snoozestack", dependencies: ["Shovelbase"], path: "Sources/Snoozestack"),
        .target(name: "SnoozestackSignals", dependencies: ["ShovelbaseSignals"], path: "Sources/SnoozestackSignals"),
        .target(name: "SnoozestackPush", dependencies: ["ShovelbasePush"], path: "Sources/SnoozestackPush"),
        // Smoke tests for the client's own wiring, plus the application
        // identity contract shared with snoozestack-js.
        .testTarget(
            name: "ShovelbaseTests",
            dependencies: ["Shovelbase"],
            path: "Tests/ShovelbaseTests"
        ),
    ]
)
