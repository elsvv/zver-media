// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverTransport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverTransport", targets: ["ZverTransport"])],
    targets: [
        .target(name: "ZverTransport"),
        .testTarget(name: "ZverTransportTests", dependencies: ["ZverTransport"]),
    ]
)
