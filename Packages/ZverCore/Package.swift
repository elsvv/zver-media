// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverCore", targets: ["ZverCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ZverCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "ZverCoreTests", dependencies: ["ZverCore"]),
    ]
)
