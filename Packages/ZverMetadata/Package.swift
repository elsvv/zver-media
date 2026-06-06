// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverMetadata",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverMetadata", targets: ["ZverMetadata"])],
    targets: [
        .target(name: "ZverMetadata"),
        .testTarget(
            name: "ZverMetadataTests",
            dependencies: ["ZverMetadata"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
