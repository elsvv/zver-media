import Foundation
import UIKit
import ZverBrain
import ZverCore

/// Итог резолва релиза через iTunes Search: релиз существует, вот его
/// метаданные из того же запроса (ссылка Apple Music, обложка, жанр, год,
/// канонические написания). `Codable` — формат дискового кэша.
struct ResolvedRelease: Codable, Equatable, Sendable {
    let itunesId: Int64
    let appleMusicURL: String?
    let artworkURL600: String?
    let genre: String?
    let year: Int?
    /// Написания артиста/альбома по версии iTunes — «второй ключ» дедупа
    /// (LLM мог назвать релиз иначе, чем каталог Apple).
    let canonicalArtist: String
    let canonicalAlbum: String
}

/// Каталог iTunes Search — эволюция ITunesArtworkFetcher: раньше только
/// обложки, теперь ещё и валидация существования рекомендаций (пайплайн
/// refresh, шаг 4) с метаданными из того же запроса.
///
/// Кэш двухслойный (память + диск в Caches/ITunesCatalog, система чистит
/// сама), негативный результат («не нашлось») кэшируется с TTL 30 дней —
/// не долбим API на каждый refresh, но даём новым релизам шанс появиться.
/// Сетевая ошибка результатом НЕ считается и не кэшируется — временный сбой
/// сети не должен хоронить кандидата на месяц.
///
/// Троттлинг 3.5с — ТОЛЬКО на промахах кэша (политика `ITunesThrottle`,
/// чистая функция в ZverBrain); тёплый кэш отвечает мгновенно.
actor ITunesCatalog {
    static let shared = ITunesCatalog()

    static let throttleInterval: TimeInterval = 3.5
    static let negativeTTL: TimeInterval = 30 * 24 * 3600

    /// Запись кэша резолва: `resolved == nil` — честное «не нашлось».
    private struct CacheEntry: Codable {
        let resolved: ResolvedRelease?
        let fetchedAt: Date
    }

    private let client: ITunesSearchClient
    private let cacheDir: URL
    private var memory: [String: CacheEntry] = [:]
    /// Дедуп параллельных резолвов одного релиза (ленивые ре-рендеры карточек).
    private var inFlight: [String: Task<CacheEntry?, Never>] = [:]
    /// Расписание троттлинга: когда разрешён следующий сетевой запрос.
    private var nextAllowedAt: Date?

    private let imageMemory = NSCache<NSString, UIImage>()
    private var imagesInFlight: [String: Task<UIImage?, Never>] = [:]

    init(client: ITunesSearchClient = ITunesSearchClient(),
         cacheDir: URL = URL.cachesDirectory.appendingPathComponent("ITunesCatalog")) {
        self.client = client
        self.cacheDir = cacheDir
    }

    // MARK: - Резолв релиза

    /// Существует ли релиз «артист + альбом» в каталоге Apple. `nil` — не
    /// нашёлся (кандидат отбрасывается) ИЛИ сеть упала (не кэшируется).
    func resolve(artist: String, album: String) async -> ResolvedRelease? {
        let key = ReleaseNorm.key(artist: artist, album: album)
        if let entry = memory[key], isFresh(entry) { return entry.resolved }

        let fileURL = cacheDir.appendingPathComponent(Self.fileName(for: key, ext: "json"))
        if let data = try? Data(contentsOf: fileURL),
           let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
           isFresh(entry) {
            memory[key] = entry
            return entry.resolved
        }

        if let task = inFlight[key] { return await task.value?.resolved }

        // Промах кэша → сетевой запрос. Слот троттлинга резервируем ДО await:
        // конкурентные промахи выстраиваются в очередь с шагом 3.5с.
        let (delay, next) = ITunesThrottle.schedule(
            now: Date(), nextAllowedAt: nextAllowedAt,
            minInterval: Self.throttleInterval)
        nextAllowedAt = next

        let task = Task<CacheEntry?, Never> { [client, cacheDir] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let results = try? await client.search(artist: artist, album: album)
            else { return nil }   // сетевая ошибка — не «не нашлось», не кэшируем

            let match = Self.pickMatch(artist: artist, album: album, from: results)
            let entry = CacheEntry(resolved: match.map(Self.release(from:)),
                                   fetchedAt: Date())
            try? FileManager.default.createDirectory(at: cacheDir,
                                                     withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(entry) {
                try? data.write(to: fileURL, options: .atomic)
            }
            return entry
        }
        inFlight[key] = task
        let entry = await task.value
        inFlight[key] = nil
        if let entry { memory[key] = entry }
        return entry?.resolved
    }

    /// Первый результат поиска, прошедший fuzzy-матч (`ReleaseNorm`):
    /// слепо верить первому нельзя — вперёд любят вылезать трибьюты и караоке.
    static func pickMatch(artist: String, album: String,
                          from results: [ITunesAlbum]) -> ITunesAlbum? {
        results.first {
            ReleaseNorm.fuzzyMatches(artist: artist, album: album,
                                     otherArtist: $0.artistName,
                                     otherAlbum: $0.collectionName)
        }
    }

    private static func release(from item: ITunesAlbum) -> ResolvedRelease {
        ResolvedRelease(itunesId: item.collectionId,
                        appleMusicURL: item.collectionViewUrl,
                        artworkURL600: item.artworkUrl600,
                        genre: item.primaryGenreName,
                        year: item.year,
                        canonicalArtist: item.artistName,
                        canonicalAlbum: item.collectionName)
    }

    /// Позитивная запись живёт, пока её не почистит система (метаданные релиза
    /// не протухают); негативная — 30 дней (новый релиз мог доехать до iTunes).
    private func isFresh(_ entry: CacheEntry) -> Bool {
        entry.resolved != nil
            || Date().timeIntervalSince(entry.fetchedAt) < Self.negativeTTL
    }

    // MARK: - Обложки

    /// Обложка по готовому URL (карточки берут `ExternalSuggestion.artworkURL`
    /// — без второго похода в поиск). Кэш память + диск; CDN не троттлим —
    /// лимитирован только Search API.
    func artwork(urlString: String) async -> UIImage? {
        if let cached = imageMemory.object(forKey: urlString as NSString) { return cached }
        if let task = imagesInFlight[urlString] { return await task.value }

        let fileURL = cacheDir.appendingPathComponent(Self.fileName(for: urlString, ext: "jpg"))
        let task = Task<UIImage?, Never> { [cacheDir] in
            if let data = try? Data(contentsOf: fileURL),
               let image = UIImage(data: data) { return image }
            guard let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            try? FileManager.default.createDirectory(at: cacheDir,
                                                     withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
            return image
        }
        imagesInFlight[urlString] = task
        let image = await task.value
        imagesInFlight[urlString] = nil
        if let image { imageMemory.setObject(image, forKey: urlString as NSString) }
        return image
    }

    /// Обложка по паре «артист + альбом» — фоллбэк для старого кэша ленты,
    /// где у рекомендаций ещё нет `artworkURL` (резолв найдёт и закэширует).
    func artwork(artist: String, album: String) async -> UIImage? {
        guard let resolved = await resolve(artist: artist, album: album),
              let urlString = resolved.artworkURL600 else { return nil }
        return await artwork(urlString: urlString)
    }

    /// Имя дискового файла — детерминированный FNV-1a от ключа
    /// (без спецсимволов файловой системы).
    private static func fileName(for key: String, ext: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "\(hash).\(ext)"
    }
}
