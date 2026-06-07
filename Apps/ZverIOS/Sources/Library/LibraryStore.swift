import Combine
import Foundation
import ZverCore
import ZverMetadata

/// Источник данных библиотеки поверх персистентного каталога (SQLite).
///
/// Старт: мгновенный publish альбомов из каталога → фоновый рескан
/// Documents → reconcile → republish. Pull-to-refresh — тот же рескан.
/// Ошибка скана не затирает уже опубликованный список.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var albums: [AlbumGroup] = []

    private let catalogStore: CatalogStore
    private let documentsURL: URL

    /// Guard от параллельных refresh: .task и .refreshable могут
    /// пересечься, второй вызов — no-op.
    private var isRefreshing = false
    private var didPublishCatalog = false

    init(catalogStore: CatalogStore, documentsURL: URL = .documentsDirectory) {
        self.catalogStore = catalogStore
        self.documentsURL = documentsURL
    }

    /// Открывает каталог в Application Support (создавая директорию).
    /// НЕ в Documents — чтобы catalog.sqlite не попадал в скан библиотеки
    /// и file sharing.
    static func openCatalog() -> Catalog {
        do {
            let dir = URL.applicationSupportDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try Catalog(path: dir.appendingPathComponent("catalog.sqlite").path)
        } catch {
            // Деградация: БД в памяти — библиотека работает сессию без
            // персистентности. In-memory миграции от внешней среды не
            // зависят, их сбой — баг схемы, а не среды выполнения.
            return try! Catalog.inMemory()
        }
    }

    /// Старт и pull-to-refresh. Первый вызов мгновенно публикует альбомы
    /// из каталога, затем (как и все последующие вызовы) рескан Documents
    /// → reconcile → republish. Тяжёлая работа — вне главного потока,
    /// publish — на MainActor.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let catalogStore = self.catalogStore
        let documentsURL = self.documentsURL

        if !didPublishCatalog {
            didPublishCatalog = true
            let cached = await Task.detached(priority: .userInitiated) {
                try? catalogStore.allTracks(documentsURL: documentsURL)
            }.value
            if let cached {
                albums = AlbumGroup.group(cached)
            }
        }

        let rescanned = await Task.detached(priority: .userInitiated) { () -> [Track]? in
            guard let infos = try? await LibraryScanner.scan(directory: documentsURL)
            else { return nil }
            let records = infos.compactMap {
                Self.record(from: $0, documentsURL: documentsURL)
            }
            do {
                try catalogStore.reconcile(scanned: records)
                return try catalogStore.allTracks(documentsURL: documentsURL)
            } catch {
                return nil
            }
        }.value

        // nil — скан/сверка упали: уже опубликованный список не трогаем.
        if let rescanned {
            albums = AlbumGroup.group(rescanned)
        }
    }

    /// AudioFileInfo → строка каталога: пути относительные от Documents.
    /// Файл вне Documents (не должно случаться) — пропускается.
    private nonisolated static func record(from info: AudioFileInfo,
                                           documentsURL: URL) -> TrackRecord? {
        guard let relativePath = relativePath(of: info.url, from: documentsURL)
        else { return nil }
        return TrackRecord(
            relativePath: relativePath,
            title: info.title,
            artist: info.artist,
            album: info.album,
            trackNumber: info.trackNumber,
            year: info.year,
            duration: info.duration,
            sampleRate: info.sampleRate,
            bitDepth: info.bitDepth,
            artworkFilePath: info.artworkFileURL.flatMap {
                Self.relativePath(of: $0, from: documentsURL)
            }
        )
    }

    private nonisolated static func relativePath(of url: URL, from base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return nil }
        return String(path.dropFirst(basePath.count + 1))
    }
}
