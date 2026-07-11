// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "shovelbase-swift",
    // Platform floors follow supabase-swift 2.x (the Shovelbase target's
    // dependency); ShovelbaseAnalytics itself has no third-party dependencies.
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        // Full client: database, auth, storage, edge functions (supabase-swift
        // API surface re-exported) + analytics.
        .library(name: "Shovelbase", targets: ["Shovelbase"]),
        // Analytics only — no third-party dependencies.
        .library(name: "ShovelbaseAnalytics", targets: ["ShovelbaseAnalytics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "Shovelbase",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                "ShovelbaseAnalytics",
            ],
            path: "Sources/Shovelbase"
        ),
        .target(name: "ShovelbaseAnalytics", path: "Sources/ShovelbaseAnalytics"),
    ]
)
