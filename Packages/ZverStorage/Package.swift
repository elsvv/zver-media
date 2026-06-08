// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverStorage",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverStorage", targets: ["ZverStorage"])],
    dependencies: [
        .package(path: "../ZverTransport"),
    ],
    targets: [
        .target(
            name: "ZverStorage",
            dependencies: ["ZverTransport"]
        ),
        .testTarget(
            name: "ZverStorageTests",
            dependencies: ["ZverStorage"]
        ),
    ]
)
