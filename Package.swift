// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "DeskBridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DeskBridge", targets: ["DeskBridgeApp"]),
        .executable(name: "DeskBridgeChecks", targets: ["DeskBridgeChecks"]),
    ],
    dependencies: [.package(path: "Vendor/Glimmer")],
    targets: [
        .target(name: "DeskBridgeCore"),
        .executableTarget(name: "DeskBridgeApp", dependencies: ["DeskBridgeCore", .product(name: "GlimmerEngine", package: "Glimmer")]),
        .executableTarget(name: "DeskBridgeChecks", dependencies: ["DeskBridgeCore", .product(name: "GlimmerEngine", package: "Glimmer")]),
    ]
)

