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
        .library(name: "SnoozeStack", targets: ["SnoozeStack"]),
        // Signals (event tracking) only — no third-party dependencies.
        .library(name: "SnoozeStackSignals", targets: ["SnoozeStackSignals"]),
        // Push notification registration only — no third-party dependencies.
        .library(name: "SnoozeStackPush", targets: ["SnoozeStackPush"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SnoozeStack",
            dependencies: [
                "SnoozeStackSignals",
                "SnoozeStackPush",
            ],
            path: "Sources/SnoozeStack"
        ),
        .target(name: "SnoozeStackSignals", path: "Sources/SnoozeStackSignals"),
        .target(name: "SnoozeStackPush", path: "Sources/SnoozeStackPush"),
        // Smoke tests for the client's own wiring, plus the application
        // identity contract shared with snoozestack-js.
        .testTarget(
            name: "SnoozeStackTests",
            dependencies: ["SnoozeStack"],
            path: "Tests/SnoozeStackTests"
        ),
    ]
)
