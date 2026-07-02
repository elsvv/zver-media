import Combine
import Foundation
import ZverCore
import ZverMetadata

/// Источник данных библиотеки поверх персистентного каталога (SQLite).
///
/// Старт: мгновенный publish альбомов из каталога → фоновый рескан
/// Documents → reconcile → republish. Pull-to-refresh — тот же рескан.
/// Ошибка скана не затирает уже опубликованный список.
///
/// Плейлисты: publish списка здесь же; все мутации (создание,
/// переименование, удаление, состав) — обёртки над PlaylistStore
/// с чтением/записью вне главного потока и republish после изменения.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var albums: [AlbumGroup] = []
    @Published private(set) var playlists: [Playlist] = []

    private let catalogStore: CatalogStore
    private let playlistStore: PlaylistStore
    private let documentsURL: URL

    /// Сервис облачного бэкапа (этап 4). Прокидывается извне после инициализации
    /// (ContentView строит оба на общем `CatalogStore`). Обёртки `offload`/`download`/
    /// `backupAll` дёргают его и republish'ат библиотеку — UI работает только через
    /// `LibraryStore`, не зная про `BackupService` напрямую. `nil` (не залогинены /
    /// сервис не подключён) → обёртки тихо no-op.
    weak var backupService: BackupService?

    /// Guard от параллельных refresh: .task и .refreshable могут
    /// пересечься, второй вызов — no-op.
    private var isRefreshing = false
    private var didPublishCatalog = false

    init(catalogStore: CatalogStore, playlistStore: PlaylistStore,
         documentsURL: URL = .documentsDirectory) {
        self.catalogStore = catalogStore
        self.playlistStore = playlistStore
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

        // Плейлисты живут в том же каталоге: публикуем вместе с альбомами,
        // чтобы подменю «В плейлист…» и раздел «Плейлисты» были готовы
        // сразу после старта.
        await refreshPlaylists()

        let rescanned = await Task.detached(priority: .userInitiated) { () -> [Track]? in
            do {
                let infos = try await LibraryScanner.scan(directory: documentsURL)
                let records = infos.compactMap {
                    Self.record(from: $0, documentsURL: documentsURL)
                }
                // keepMissing: трек выпал из скана, но файл на месте —
                // не прочитался (частично скопирован через file sharing,
                // временный сбой чтения). Удаление потеряло бы addedAt
                // и плейлистные связи (каскад) безвозвратно.
                try catalogStore.reconcile(scanned: records, keepMissing: {
                    FileManager.default.fileExists(
                        atPath: documentsURL.appendingPathComponent($0).path
                    )
                })
                return try catalogStore.allTracks(documentsURL: documentsURL)
            } catch {
                // Скан корня (директория недоступна) или сверка упали —
                // это не «пустая библиотека», каталог не трогаем.
                return nil
            }
        }.value

        // nil — скан/сверка упали: уже опубликованный список не трогаем.
        if let rescanned {
            albums = AlbumGroup.group(rescanned)
        }
    }

    /// Поиск по каталогу: подстрока в title/artist/album без учёта
    /// регистра (CatalogStore.search), пустой/пробельный запрос → [].
    /// Чтение БД — вне главного потока, как и остальные выборки.
    /// Ошибка чтения каталога эквивалентна пустому результату.
    func search(query: String) async -> [Track] {
        let catalogStore = self.catalogStore
        let documentsURL = self.documentsURL
        return await Task.detached(priority: .userInitiated) {
            (try? catalogStore.search(query, documentsURL: documentsURL)) ?? []
        }.value
    }

    // MARK: - Облако (обёртки над BackupService, этап 4)

    /// «Выгрузить»: удаляет локальную копию трека, оставляя его только в облаке
    /// (`backedUp` → `remote`). Делегирует ``BackupService/offload(track:)`` (гейт:
    /// только `backedUp` с подтверждённым `cloudSha`, повторная сверка наличия в
    /// облаке перед удалением). После — republish, чтобы бейдж стал ☁️. Возвращает
    /// `true`, если файл выгружен.
    @discardableResult
    func offload(track: Track) async -> Bool {
        guard let backupService else { return false }
        let ok = await backupService.offload(track: track)
        if ok { await refresh() }
        return ok
    }

    /// «Скачать»: возвращает `remote`-трек на устройство из облака (докачка + сверка
    /// sha), делегируя ``BackupService/download(track:)``. После — republish (бейдж
    /// становится ☁️✓, ряд снова играбелен). Возвращает `true` при успехе.
    @discardableResult
    func download(track: Track) async -> Bool {
        guard let backupService else { return false }
        let ok = await backupService.download(track: track)
        if ok { await refresh() }
        return ok
    }

    /// Ставит в очередь и выгружает все `local`-треки (автобэкап) + бэкапит каталог.
    /// Делегирует ``BackupService/backupAwaitingTracks()``, затем republish.
    func backupAll() async {
        guard let backupService else { return }
        await backupService.backupAwaitingTracks()
        await refresh()
    }

    /// Восстановление из облака: качает бэкап каталога, импортирует записи как
    /// `remote`, republish. Делегирует ``BackupService/restore()``. Возвращает число
    /// импортированных записей при успехе, `nil` — при ошибке/отсутствии сервиса.
    @discardableResult
    func restore() async -> Int? {
        guard let backupService else { return nil }
        let count = await backupService.restore()
        if count != nil { await refresh() }
        return count
    }

    // MARK: - Плейлисты

    /// Перечитывает плейлисты из каталога и публикует список.
    /// Ошибка чтения не затирает уже опубликованный список.
    func refreshPlaylists() async {
        let playlistStore = self.playlistStore
        let fetched = await Task.detached(priority: .userInitiated) {
            try? playlistStore.allPlaylists()
        }.value
        if let fetched {
            playlists = fetched
        }
    }

    /// Создаёт плейлист и публикует обновлённый список.
    /// Пустое/пробельное имя или ошибка записи → nil.
    @discardableResult
    func createPlaylist(title: String) async -> Playlist? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let playlistStore = self.playlistStore
        let created = await Task.detached(priority: .userInitiated) {
            try? playlistStore.createPlaylist(title: title)
        }.value
        await refreshPlaylists()
        return created
    }

    /// Переименовывает плейлист (пустое имя — no-op) и публикует список.
    func renamePlaylist(id: Int64, title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let playlistStore = self.playlistStore
        await Task.detached(priority: .userInitiated) {
            _ = try? playlistStore.renamePlaylist(id: id, title: title)
        }.value
        await refreshPlaylists()
    }

    /// Удаляет плейлист (состав чистится каскадом) и публикует список.
    func deletePlaylist(id: Int64) async {
        let playlistStore = self.playlistStore
        await Task.detached(priority: .userInitiated) {
            _ = try? playlistStore.deletePlaylist(id: id)
        }.value
        await refreshPlaylists()
    }

    /// Треки плейлиста по позициям. Ошибка чтения → [].
    func playlistTracks(id: Int64) async -> [Track] {
        let playlistStore = self.playlistStore
        let documentsURL = self.documentsURL
        return await Task.detached(priority: .userInitiated) {
            (try? playlistStore.tracks(in: id, documentsURL: documentsURL)) ?? []
        }.value
    }

    /// Добавляет трек в конец плейлиста (дубликат игнорируется).
    /// Трек вне Documents (не должно случаться) — no-op.
    func addToPlaylist(track: Track, playlistId: Int64) async {
        guard let path = Self.relativePath(of: track.url, from: documentsURL)
        else { return }
        let playlistStore = self.playlistStore
        await Task.detached(priority: .userInitiated) {
            _ = try? playlistStore.add(trackPath: path, to: playlistId)
        }.value
    }

    /// Убирает трек из плейлиста (позиции перенумеровываются в сторе).
    func removeFromPlaylist(track: Track, playlistId: Int64) async {
        guard let path = Self.relativePath(of: track.url, from: documentsURL)
        else { return }
        let playlistStore = self.playlistStore
        await Task.detached(priority: .userInitiated) {
            _ = try? playlistStore.remove(trackPath: path, from: playlistId)
        }.value
    }

    /// Переставляет трек на позицию `position` в плейлисте.
    func moveInPlaylist(track: Track, playlistId: Int64, to position: Int) async {
        guard let path = Self.relativePath(of: track.url, from: documentsURL)
        else { return }
        let playlistStore = self.playlistStore
        await Task.detached(priority: .userInitiated) {
            _ = try? playlistStore.move(trackPath: path, in: playlistId, to: position)
        }.value
    }

    // MARK: - Маппинг записей

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
            discNumber: info.discNumber,
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
