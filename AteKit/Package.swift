// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AteKit",
    platforms: [
        .iOS("26.0"),
        // Host platform for `swift test` only — AteKit ships to iOS.
        .macOS("15.0")
    ],
    products: [
        .library(name: "AteKit", targets: ["AteKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0")
    ],
    targets: [
        .target(
            name: "AteKit",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AteKitTests",
            dependencies: ["AteKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
