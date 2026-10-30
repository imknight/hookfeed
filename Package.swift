// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HookFeed",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HookFeedCore", targets: ["HookFeedCore"]),
        .executable(name: "hookfeed", targets: ["HookFeedCLI"]),
        // Different spelling from the CLI avoids swiftbuild product-directory
        // collisions on the default case-insensitive macOS filesystem.
        .executable(name: "HookFeedDesktop", targets: ["HookFeedApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "HookFeedCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .executableTarget(name: "HookFeedCLI", dependencies: [
            "HookFeedCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "HookFeedApp", dependencies: [
            "HookFeedCore", .product(name: "Sparkle", package: "Sparkle"),
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "HookFeedAppTests", dependencies: ["HookFeedApp"], exclude: ["__Snapshots__", "README.md"]),
        .testTarget(name: "HookFeedCoreTests", dependencies: [
            "HookFeedCore", "HookFeedCLI", .product(name: "GRDB", package: "GRDB.swift"),
        ], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)
