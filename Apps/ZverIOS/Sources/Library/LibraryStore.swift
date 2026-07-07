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
    @Published private(set) var albums: [AlbumGroup] = [] {
        didSet { albumKeyIndex = nil }
    }
    @Published private(set) var playlists: [Playlist] = []
    /// Избранное: ключи в каталожном формате (относительные от Documents —
    /// стабильны между реинсталлами, в отличие от абсолютных путей `Track.id`/
    /// `AlbumGroup.id` с UUID контейнера). Публикуются для сердечек в рядах.
    @Published private(set) var favoriteTrackKeys: Set<String> = []
    @Published private(set) var favoriteAlbumKeys: Set<String> = []

    private let catalogStore: CatalogStore
    private let playlistStore: PlaylistStore
    /// Сторы избранного, истории и памяти рекомендаций (та же БД каталога).
    /// nil — фичи выключены (тесты/превью со старым инитом).
    private let favoriteStore: FavoriteStore?
    private let historyStore: PlayHistoryStore?
    private let recommendationStore: RecommendationStore?
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
         favoriteStore: FavoriteStore? = nil,
         historyStore: PlayHistoryStore? = nil,
         recommendationStore: RecommendationStore? = nil,
         documentsURL: URL = .documentsDirectory) {
        self.catalogStore = catalogStore
        self.playlistStore = playlistStore
        self.favoriteStore = favoriteStore
        self.historyStore = historyStore
        self.recommendationStore = recommendationStore
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
        await refreshFavorites()

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

    // MARK: - Управление альбомами (удаление/выгрузка/переименование)
    //
    // Все методы принимают СПИСОК альбомов (один — контекст-меню, несколько —
    // мультивыбор) и делают ОДИН republish в конце. Опасные — под confirm в UI.

    /// «Убрать с устройства»: забэкапленные треки выгружаются в облако (локальные
    /// файлы удаляются, альбом становится `remote`/серым; обложка/плейлист остаются
    /// для показа). Незабэкапленные треки не трогает (иначе потеряли бы единственную
    /// копию — для них в UI показывается «Удалить»).
    func removeFromDevice(_ groups: [AlbumGroup]) async {
        for group in groups {
            for track in Self.containerRepresentatives(group.tracks) where track.fileState == .backedUp {
                _ = await backupService?.offload(track: track)
            }
        }
        await refresh()
    }

    /// «Скачать»: возвращает облачные (`remote`) треки альбомов на устройство.
    func downloadAlbums(_ groups: [AlbumGroup]) async {
        for group in groups {
            for track in Self.containerRepresentatives(group.tracks) where track.fileState == .remote {
                _ = await backupService?.download(track: track)
            }
        }
        await refresh()
    }

    /// «Бэкап в облако»: делегирует общий автобэкап ожидающих `local`-треков.
    func backupAlbums(_ groups: [AlbumGroup]) async { await backupAll() }

    /// Полное локальное удаление: сносит папки альбомов (аудио, обложка, плейлист,
    /// sidecar) и строки каталога. Облачные копии не трогает.
    func deleteLocally(_ groups: [AlbumGroup]) async {
        for group in groups {
            await removeAlbumFolder(group)
            await removeCatalogRows(group)
        }
        await refresh()
    }

    /// «Удалить из облака»: удаляет облачные копии. Локальные файлы остаются —
    /// треки снова становятся `local` (строки удаляются, рескан подхватывает);
    /// облачные-только треки исчезают.
    func deleteFromCloud(_ groups: [AlbumGroup]) async {
        for group in groups {
            await deleteCloudCopies(group)
            await removeCatalogRows(group)
        }
        await refresh()
    }

    /// «Удалить везде»: облачные копии + папки альбомов + строки каталога.
    func deleteEverywhere(_ groups: [AlbumGroup]) async {
        for group in groups {
            await deleteCloudCopies(group)
            await removeAlbumFolder(group)
            await removeCatalogRows(group)
        }
        await refresh()
    }

    /// Переименование альбома: пишет per-track override тега ALBUM в sidecar
    /// (сливая с существующим), рескан меняет отображаемое название. Идентичность
    /// (папка) не меняется.
    func renameAlbum(_ group: AlbumGroup, to newTitle: String) async {
        await editAlbum(group, title: newTitle, artist: nil, year: nil)
    }

    /// Правка метадаты альбома на телефоне: название / артист альбома / год —
    /// per-track override'ами в sidecar (пустое или неизменённое поле — не
    /// трогаем), затем рескан накладывает overlay. Правки переживают реинсталл
    /// и рескан (sidecar — источник правды), но перезаливка альбома с Мака
    /// перезапишет sidecar правками Мака — осознанно (при синке Мак главнее).
    /// Типичный кейс: артистом альбома подхватился feat.-гость — правим разом
    /// во всех треках.
    func editAlbum(_ group: AlbumGroup, title: String?, artist: String?, year: Int?) async {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasChanges = !(title ?? "").isEmpty || !(artist ?? "").isEmpty || year != nil
        guard hasChanges,
              let folder = Self.albumFolderURL(for: group, documentsURL: documentsURL)
        else { return }
        let relPaths = group.tracks.map { Self.relativePathWithinAlbum($0.url, folder: folder) }
        await Task.detached(priority: .utility) {
            Self.writeAlbumOverrides(folder: folder, trackRelPaths: relPaths) { override in
                if let title, !title.isEmpty { override.album = title }
                if let artist, !artist.isEmpty { override.artist = artist }
                if let year { override.year = year }
            }
        }.value
        await refresh()
    }

    private func deleteCloudCopies(_ group: AlbumGroup) async {
        for track in Self.containerRepresentatives(group.tracks)
        where track.fileState == .backedUp || track.fileState == .remote {
            _ = await backupService?.deleteFromCloud(track: track)
        }
    }

    /// Дедуп треков по контейнеру (физическому `url` `.flac`): у cue-альбома N
    /// логических треков делят один файл, а облачная операция (upload/download/
    /// offload/delete) — это одна физическая передача контейнера. Возвращает по
    /// одному представителю на уникальный `url` (в исходном порядке), чтобы не
    /// гонять один и тот же `.flac` N раз. Для обычных треков (у каждого свой файл) —
    /// no-op. `fileState` у N cue-строк синхронен (лок-степ), поэтому представитель
    /// корректно отражает состояние всего контейнера.
    private static func containerRepresentatives(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.url.path).inserted }
    }

    /// Сносит папку альбома целиком (если она внутри Documents); иначе — только
    /// файлы треков. Работа с ФС — вне главного потока.
    private func removeAlbumFolder(_ group: AlbumGroup) async {
        if let folder = Self.albumFolderURL(for: group, documentsURL: documentsURL) {
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: folder)
            }.value
        } else {
            let urls = group.tracks.map(\.url)
            await Task.detached(priority: .utility) {
                for url in urls { try? FileManager.default.removeItem(at: url) }
            }.value
        }
    }

    private func removeCatalogRows(_ group: AlbumGroup) async {
        let paths = group.tracks.compactMap { Self.relativePath(of: $0.url, from: documentsURL) }
        let store = catalogStore
        await Task.detached(priority: .utility) {
            try? store.deleteTracks(relativePaths: paths)
        }.value
    }

    /// Папка альбома (`group.id`), только если это реальная директория ВНУТРИ
    /// Documents (защита от сноса произвольного пути). Иначе nil.
    private nonisolated static func albumFolderURL(for group: AlbumGroup, documentsURL: URL) -> URL? {
        guard group.id != AlbumGroup.noAlbumTitle else { return nil }
        let url = URL(fileURLWithPath: group.id).standardizedFileURL
        let base = documentsURL.standardizedFileURL.path
        guard url.path.hasPrefix(base + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    private nonisolated static func relativePathWithinAlbum(_ url: URL, folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    /// Мёржит правку в sidecar альбома: читает существующий (или создаёт пустой),
    /// применяет `mutate` к override'у КАЖДОГО трека и атомарно пишет обратно.
    /// Прочие поля sidecar (обложка, описание, чужие override'ы) не трогаются.
    private nonisolated static func writeAlbumOverrides(
        folder: URL, trackRelPaths: [String],
        mutate: (inout TrackOverride) -> Void
    ) {
        let sidecarURL = folder.appendingPathComponent(AlbumSidecar.fileName)
        var sidecar: AlbumSidecar
        if let data = try? Data(contentsOf: sidecarURL),
           let existing = try? JSONDecoder().decode(AlbumSidecar.self, from: data) {
            sidecar = existing
        } else {
            sidecar = AlbumSidecar(version: 1)
        }
        for rel in trackRelPaths {
            var override = sidecar.tracks[rel] ?? TrackOverride()
            mutate(&override)
            sidecar.tracks[rel] = override
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sidecar) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }

    // MARK: - Избранное и история
    //
    // Ключи — в каталожном формате (относительные от Documents): abs-пути
    // (`Track.id`, `AlbumGroup.id`) содержат UUID контейнера приложения и
    // не переживают реинсталл, а избранное с историей — должны (та же БД,
    // что у плейлистов, уезжает в облачный бэкап каталога).

    /// Каталожный `trackKey` трека: относительный путь + `#cueIndex` у
    /// cue-треков (зеркало `Track.id`, но переносимое). Трек вне Documents → nil.
    nonisolated private static func trackKey(for track: Track, documentsURL: URL) -> String? {
        guard let rel = relativePath(of: track.url, from: documentsURL) else { return nil }
        if let cueIndex = track.cueIndex { return "\(rel)#\(cueIndex)" }
        return rel
    }

    /// Переносимый ключ альбома: путь папки относительно Documents.
    /// Группа «Без альбома» — её константное имя (тоже стабильно).
    nonisolated private static func albumKey(for group: AlbumGroup, documentsURL: URL) -> String? {
        guard group.id != AlbumGroup.noAlbumTitle else { return AlbumGroup.noAlbumTitle }
        return relativePath(of: URL(fileURLWithPath: group.id), from: documentsURL)
    }

    func isFavorite(track: Track) -> Bool {
        Self.trackKey(for: track, documentsURL: documentsURL)
            .map(favoriteTrackKeys.contains) ?? false
    }

    func isFavorite(album group: AlbumGroup) -> Bool {
        Self.albumKey(for: group, documentsURL: documentsURL)
            .map(favoriteAlbumKeys.contains) ?? false
    }

    func toggleFavorite(track: Track) async {
        guard let key = Self.trackKey(for: track, documentsURL: documentsURL) else { return }
        await setFavorite(kind: .track, key: key, isFavorite: !favoriteTrackKeys.contains(key))
    }

    func toggleFavorite(album group: AlbumGroup) async {
        guard let key = Self.albumKey(for: group, documentsURL: documentsURL) else { return }
        await setFavorite(kind: .album, key: key, isFavorite: !favoriteAlbumKeys.contains(key))
    }

    private func setFavorite(kind: FavoriteKind, key: String, isFavorite: Bool) async {
        guard let favoriteStore else { return }
        await Task.detached(priority: .userInitiated) {
            try? favoriteStore.setFavorite(kind: kind, key: key, isFavorite: isFavorite)
        }.value
        await refreshFavorites()
    }

    /// Перечитывает ключи избранного. Ошибка чтения не затирает опубликованное.
    func refreshFavorites() async {
        guard let favoriteStore else { return }
        let fetched = await Task.detached(priority: .userInitiated) {
            () -> (tracks: Set<String>, albums: Set<String>)? in
            guard let tracks = try? favoriteStore.favoriteKeys(kind: .track),
                  let albums = try? favoriteStore.favoriteKeys(kind: .album)
            else { return nil }
            return (tracks, albums)
        }.value
        if let fetched {
            favoriteTrackKeys = fetched.tracks
            favoriteAlbumKeys = fetched.albums
        }
    }

    /// Переносимый ключ альбома для внешних потребителей (лента «Главной»,
    /// история): относительный путь папки. См. albumKey(for:documentsURL:).
    func albumKey(of group: AlbumGroup) -> String? {
        Self.albumKey(for: group, documentsURL: documentsURL)
    }

    /// Ленивый индекс ключ → альбом. Сбрасывается при каждом publish albums
    /// (didSet); строится по требованию. Нужен ленте «Главной»: резолв ключей
    /// в рендер-пути, линейный поиск с нормализацией путей на каждый вызов —
    /// десятки тысяч лишних вычислений на один проход body.
    private var albumKeyIndex: [String: AlbumGroup]?

    /// Альбом по переносимому ключу (через ленивый индекс).
    func album(forKey key: String) -> AlbumGroup? {
        if albumKeyIndex == nil {
            albumKeyIndex = Dictionary(
                albums.compactMap { group in albumKey(of: group).map { ($0, group) } },
                // Ключ (путь папки) уникален на группу по построению; дубликат
                // означал бы сломанный инвариант — не падаем, берём первую.
                uniquingKeysWith: { first, _ in first })
        }
        return albumKeyIndex?[key]
    }

    /// Последние прослушанные альбомы (различные, по свежести последнего
    /// события) — локальная секция «Главной». История выключена/пуста → [].
    func recentlyPlayedAlbums(limit: Int) async -> [AlbumGroup] {
        guard let historyStore else { return [] }
        let keys = await Task.detached(priority: .userInitiated) {
            (try? historyStore.recentAlbumKeys(limit: limit)) ?? []
        }.value
        // Порядок ключей истории сохраняем (свежие первыми).
        return keys.compactMap { album(forKey: $0) }
    }

    /// Агрегат прослушивания за период (сырьё промпта AI-ленты).
    func listeningStats(since: Date) async -> ListeningStats? {
        guard let historyStore else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? historyStore.listeningStats(since: since)
        }.value
    }

    /// Систематически скипаемые артисты (анти-сигнал промпта AI-ленты).
    func skippedArtists(since: Date, minSkips: Int) async -> [String] {
        guard let historyStore else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? historyStore.skippedArtists(since: since, minSkips: minSkips)) ?? []
        }.value
    }

    // MARK: - Память рекомендаций (Предложка v2)

    /// Срез фидбека по рекомендациям для промпта (♥ / «не моё» / показанное).
    func recommendationFeedback(likedLimit: Int, hiddenLimit: Int,
                                shownWindow: Date) async -> RecFeedback? {
        guard let recommendationStore else { return nil }
        return await Task.detached(priority: .userInitiated) {
            try? recommendationStore.feedback(likedLimit: likedLimit,
                                              hiddenLimit: hiddenLimit,
                                              shownWindow: shownWindow)
        }.value
    }

    /// Ключи показанного с `since` (для дедупа ленты); `excluding` вычитает
    /// статусы (дизайн: за 90 дней кроме liked).
    func shownRecommendationKeys(since: Date,
                                 excluding: Set<RecommendationStatus> = []) async -> Set<String> {
        guard let recommendationStore else { return [] }
        return await Task.detached(priority: .userInitiated) {
            (try? recommendationStore.shownKeys(since: since, excluding: excluding)) ?? []
        }.value
    }

    /// Фиксирует показ прошедших валидацию рекомендаций (upsert по normKey).
    func recordShownRecommendations(_ recs: [Recommendation]) async {
        guard let recommendationStore, !recs.isEmpty else { return }
        await Task.detached(priority: .utility) {
            for rec in recs {
                try? recommendationStore.recordShown(rec)
            }
        }.value
    }

    /// Избранные альбомы в порядке библиотеки (для раздела «Избранное»).
    var favoriteAlbums: [AlbumGroup] {
        albums.filter { isFavorite(album: $0) }
    }

    /// Избранные треки в порядке библиотеки (альбом → номер трека).
    var favoriteTracks: [Track] {
        albums.flatMap(\.tracks).filter { isFavorite(track: $0) }
    }

    /// Запись события истории (колбэк `PlayerEngine.onTrackPlayed`): снапшот
    /// метадаты + переносимые ключи. События короче секунды не пишем — это
    /// «пролистывание» очереди, не прослушивание (защита от мусора в истории).
    func recordPlayEvent(track: Track, startedAt: Date,
                         playedSeconds: Double, reason: PlaybackEndReason) {
        guard let historyStore,
              playedSeconds >= 1,
              let trackKey = Self.trackKey(for: track, documentsURL: documentsURL)
        else { return }
        // Идентичность альбома — как у AlbumGroup (папка с учётом сворачивания
        // диск-подпапок CD1/CD2), иначе albumKey истории не сджойнится с
        // AlbumGroup.id и избранным. У треков без тега альбома albumKey = nil
        // (спека: папка одиночек — не «альбом» для «Недавно прослушанного»).
        let albumKey: String?
        if track.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            albumKey = Self.relativePath(
                of: URL(fileURLWithPath: AlbumGroup.albumFolderPath(for: track)),
                from: documentsURL)
        } else {
            albumKey = nil
        }
        let event = PlayEvent(
            trackKey: trackKey,
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumKey: albumKey,
            startedAt: startedAt,
            playedSeconds: playedSeconds,
            trackDuration: track.duration,
            endReason: PlayEndReason(rawValue: reason.rawValue) ?? .stopped
        )
        Task.detached(priority: .utility) {
            try? historyStore.record(event)
        }
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
        // Cue-трек — «вырезка» из общего контейнера: длительность у скана осталась
        // по всему файлу, для трека берём её из числа сэмплов диапазона (по треку
        // считают слайдер/локскрин/мини-плеер; последний трек — оценка, плеер
        // уточнит по факту). Обычный трек — длительность файла как есть.
        let duration: Double
        if let frameCount = info.frameCount, info.sampleRate > 0 {
            duration = Double(frameCount) / info.sampleRate
        } else {
            duration = info.duration
        }
        return TrackRecord(
            relativePath: relativePath,
            title: info.title,
            artist: info.artist,
            album: info.album,
            trackNumber: info.trackNumber,
            discNumber: info.discNumber,
            discLabel: info.discLabel,
            year: info.year,
            duration: duration,
            sampleRate: info.sampleRate,
            bitDepth: info.bitDepth,
            artworkFilePath: info.artworkFileURL.flatMap {
                Self.relativePath(of: $0, from: documentsURL)
            },
            cueIndex: info.cueIndex,
            startFrame: info.startFrame,
            frameCount: info.frameCount
        )
    }

    private nonisolated static func relativePath(of url: URL, from base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return nil }
        return String(path.dropFirst(basePath.count + 1))
    }
}
