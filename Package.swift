// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "shovelbase-swift",
    // Platform floors follow the upstream client 2.x (the Shovelbase target's
    // dependency); ShovelbaseSignals and ShovelbaseFlags themselves have no
    // third-party dependencies.
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // Full client: database, auth, storage, edge functions (upstream client
        // API surface re-exported) + signals + feature flags.
        .library(name: "Shovelbase", targets: ["Shovelbase"]),
        // Signals (event tracking) only — no third-party dependencies.
        .library(name: "ShovelbaseSignals", targets: ["ShovelbaseSignals"]),
        // Deprecated alias of ShovelbaseSignals — kept for existing importers.
        .library(name: "ShovelbaseAnalytics", targets: ["ShovelbaseAnalytics"]),
        // Feature flags only — no third-party dependencies.
        .library(name: "ShovelbaseFlags", targets: ["ShovelbaseFlags"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "Shovelbase",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                "ShovelbaseSignals",
                "ShovelbaseFlags",
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
        .target(name: "ShovelbaseFlags", path: "Sources/ShovelbaseFlags"),
    ]
)
