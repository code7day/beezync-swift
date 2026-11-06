// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BeezyncSDK",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "BeezyncSDK", targets: ["BeezyncSDK"])
    ],
    targets: [
        .target(name: "BeezyncSDK"),
        .testTarget(name: "BeezyncSDKTests", dependencies: ["BeezyncSDK"])
    ]
)
