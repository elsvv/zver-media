// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverBrain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverBrain", targets: ["ZverBrain"])],
    // Пакет автономен: зависимостей на другие пакеты репо НЕТ. Только чистая
    // логика (промпт, парсер, модели) + тонкий URLSession-клиент — как ZverStorage,
    // но без общего кода, чтобы «мозг» можно было вынести/переиспользовать отдельно.
    targets: [
        .target(name: "ZverBrain"),
        .testTarget(
            name: "ZverBrainTests",
            dependencies: ["ZverBrain"]
        ),
    ]
)
