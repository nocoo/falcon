// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Falcon", platforms: [.macOS(.v15)],
    products: [
        .library(name: "FalconCore", targets: ["FalconCore"]), .executable(name: "Falcon", targets: ["Falcon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.27.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "FalconCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"), .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]), .executableTarget(name: "Falcon", dependencies: ["FalconCore"], resources: [.process("Resources")]),
        .testTarget(name: "FalconCoreTests", dependencies: ["FalconCore"]),
        .testTarget(
            name: "FalconIntegrationTests",
            dependencies: [
                "FalconCore", .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ]),
    ], swiftLanguageModes: [.v6])
