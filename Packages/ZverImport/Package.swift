// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverImport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverImport", targets: ["ZverImport"])],
    dependencies: [
        .package(path: "../ZverMetadata"),
        .package(path: "../ZverTransport"),
        // Вторая внешняя зависимость репо (после GRDB): zip-контейнер читаем
        // готовым парсером — Compression/AppleArchive формат .zip не понимают.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "ZverImport",
            dependencies: [
                "ZverMetadata",
                "ZverTransport",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "ZverImportTests",
            dependencies: [
                "ZverImport",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
