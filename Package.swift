// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "snoozestack-swift",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // Full client: application identity + functions + signals + push.
        .library(name: "Snoozestack", targets: ["Snoozestack"]),
        // Signals (event tracking) only — no third-party dependencies.
        .library(name: "SnoozestackSignals", targets: ["SnoozestackSignals"]),
        // Deprecated alias of SnoozestackSignals — kept for existing importers.
        .library(name: "SnoozestackAnalytics", targets: ["SnoozestackAnalytics"]),
        // Push notification registration only — no third-party dependencies.
        .library(name: "SnoozestackPush", targets: ["SnoozestackPush"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Snoozestack",
            dependencies: [
                "SnoozestackSignals",
                "SnoozestackPush",
            ],
            path: "Sources/Snoozestack"
        ),
        .target(name: "SnoozestackSignals", path: "Sources/SnoozestackSignals"),
        // Thin re-export of SnoozestackSignals; keeps `import
        // SnoozestackAnalytics` working after that module's own rename.
        .target(
            name: "SnoozestackAnalytics",
            dependencies: ["SnoozestackSignals"],
            path: "Sources/SnoozestackAnalytics"
        ),
        .target(name: "SnoozestackPush", path: "Sources/SnoozestackPush"),
        // Smoke tests for the client's own wiring, plus the application
        // identity contract shared with snoozestack-js.
        .testTarget(
            name: "SnoozestackTests",
            dependencies: ["Snoozestack"],
            path: "Tests/SnoozestackTests"
        ),
    ]
)
