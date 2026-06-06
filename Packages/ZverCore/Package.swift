// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverCore", targets: ["ZverCore"])],
    targets: [
        .target(name: "ZverCore"),
        .testTarget(name: "ZverCoreTests", dependencies: ["ZverCore"]),
    ]
)
