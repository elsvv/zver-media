import Foundation
import UIKit

/// Обложки для внешних рекомендаций «что скачать» — iTunes Search API
/// (бесплатный, без ключа). Ищем `artist album`, берём artworkUrl100 и
/// поднимаем до 600×600 (стандартный трюк с подменой суффикса размера).
/// Ошибки тихие: UI показывает шейдерный фоллбэк.
///
/// Кэш двухслойный: NSCache в памяти + файлы в Caches (система чистит сама).
/// Негативный результат (ничего не нашлось) в памяти тоже запоминается, чтобы
/// не долбить API на каждый показ карточки.
actor ITunesArtworkFetcher {
    static let shared = ITunesArtworkFetcher()

    private let memory = NSCache<NSString, UIImage>()
    private var missing: Set<String> = []
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let cacheDir: URL

    init(cacheDir: URL = URL.cachesDirectory.appendingPathComponent("HomeArtwork")) {
        self.cacheDir = cacheDir
    }

    func artwork(artist: String, album: String) async -> UIImage? {
        let key = "\(artist) — \(album)".lowercased()
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if missing.contains(key) { return nil }

        // Дедуп параллельных запросов одной карточки (ленивые ре-рендеры).
        if let task = inFlight[key] { return await task.value }
        let task = Task<UIImage?, Never> { [cacheDir] in
            await Self.load(artist: artist, album: album, cacheDir: cacheDir)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            memory.setObject(image, forKey: key as NSString)
        } else {
            missing.insert(key)
        }
        return image
    }

    private static func load(artist: String, album: String,
                             cacheDir: URL) async -> UIImage? {
        let fileURL = cacheDir.appendingPathComponent(
            diskFileName(artist: artist, album: album))
        if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
            return image
        }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "album"),
            .init(name: "limit", value: "1"),
            .init(name: "term", value: "\(artist) \(album)"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data),
              let small = response.results.first?.artworkUrl100
        else { return nil }

        // 100×100 → 600×600: iTunes CDN отдаёт любой размер по имени файла.
        let bigURL = small.replacingOccurrences(of: "100x100", with: "600x600")
        guard let artURL = URL(string: bigURL),
              let (artData, _) = try? await URLSession.shared.data(from: artURL),
              let image = UIImage(data: artData)
        else { return nil }

        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
        try? artData.write(to: fileURL, options: .atomic)
        return image
    }

    /// Имя дискового файла — детерминированный FNV-1a от пары артист+альбом
    /// (без спецсимволов файловой системы).
    private static func diskFileName(artist: String, album: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(artist)|\(album)".lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "\(hash).jpg"
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable { let artworkUrl100: String? }
        let results: [Item]
    }
}
