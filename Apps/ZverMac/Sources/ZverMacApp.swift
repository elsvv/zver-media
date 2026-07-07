import SwiftUI
import UniformTypeIdentifiers
import ZverMetadata
import ZverTransport

/// Mac-компаньон Zver Media.
///
/// Полноценное приложение (Dock + alt-tab): одно окно с сайдбаром
/// Синк / Библиотека / Пульт (`RootView`/`NavigationSplitView`). Меню-бар-экстра
/// остаётся как быстрый статус очереди/раздачи и точка «Открыть Zver Media».
@main
struct ZverMacApp: App {
    @NSApplicationDelegateAdaptor(ZverAppDelegate.self) private var appDelegate
    @StateObject private var queue: OutgoingQueue
    @StateObject private var dropController = DropController()
    /// Координатор сетевой раздачи (сервер + Bonjour + pairing). Создаётся поверх
    /// той же очереди, что и UI: стартует сервер при непустой очереди.
    @StateObject private var server: ServerCoordinator
    /// Координатор пульта (этап 5): browse `_zver._tcp svc=remote` → WS-клиент к
    /// iPhone → приём состояния/библиотеки/обложек, отправка команд. Живёт всё
    /// время работы приложения; browse стартует на появлении окна (`RootView`).
    @StateObject private var remote = RemoteClientCoordinator()

    init() {
        let queue = OutgoingQueue()
        // Память о доставленных альбомах: на confirm телефон помечает альбом здесь,
        // и стартовая автоочередь его больше не возвращает (иначе синкнутые альбомы
        // всплывали бы в очереди на КАЖДОМ запуске).
        let delivered = DeliveredStore()
        _queue = StateObject(wrappedValue: queue)
        _server = StateObject(wrappedValue: ServerCoordinator(queue: queue, delivered: delivered))
        // Программный автосинк: после старта читаем ~/.zver-autoqueue (список папок-
        // альбомов, по строке на путь) и ставим в очередь ТОЛЬКО не-доставленные —
        // «агент кладёт список → новая музыка в очереди, на телефоне один тап Импорт».
        ZverAppDelegate.onLaunch = {
            Task { @MainActor in
                // Осиротевший с прошлой сессии staging (очередь в памяти пуста —
                // раздавать нечего) чистим ДО автоочереди, чтобы не гонки: она сама
                // пере-материализует нужные DSD-альбомы.
                await Task.detached(priority: .utility) { DSDStaging.sweepAll() }.value
                MacEnqueue.runStartupAutoqueue(queue: queue, delivered: delivered)
            }
        }
    }

    var body: some Scene {
        Window("Zver Media", id: "main") {
            RootView(queue: queue, dropController: dropController, server: server, remote: remote)
        }
        .defaultSize(width: 940, height: 640)

        MenuBarExtra("Zver Media", systemImage: "music.note.house") {
            MenuBarContent(queue: queue, server: server)
        }
    }
}

/// Содержимое меню-бара: краткий статус очереди/раздачи + «Открыть Zver Media».
private struct MenuBarContent: View {
    @ObservedObject var queue: OutgoingQueue
    @ObservedObject var server: ServerCoordinator
    /// Открывает/фокусирует главное окно даже если оно было закрыто
    /// (`NSApp.activate` закрытую SwiftUI-сцену не воскрешает).
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if queue.isEmpty {
            Text("Очередь пуста")
        } else {
            Text("В очереди: \(queue.albums.count)")
            Divider()
            ForEach(queue.albums) { album in
                Text(album.manifestAlbum.title)
            }
        }
        Divider()
        switch server.status {
        case .stopped:
            Text("Раздача не запущена")
        case let .running(port):
            Text("Раздаю в сети (порт \(port))")
        case let .failed(message):
            Text(message)
        }
        Divider()
        Button("Открыть Zver Media") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Выйти") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// Программная постановка папок-альбомов в очередь (без превью/drag-drop) —
/// для автосинка агентом. Тот же путь, что и ручной enqueue: скан → черновик →
/// манифест (хеширование вне главного потока) → очередь.
enum MacEnqueue {
    @MainActor
    static func enqueueFolder(_ folder: URL, into queue: OutgoingQueue, delivered: DeliveredStore) async {
        // Уже доставлен на телефон и содержимое не менялось — пропускаем целиком: не
        // сканируем, не хешируем, не ставим в очередь. Отпечаток (только stat) считаем
        // вне MainActor. Поменяли исходники → отпечаток другой → альбом пере-ставится.
        let fingerprint = await Task.detached(priority: .utility) {
            DeliveredStore.fingerprint(of: folder)
        }.value
        if delivered.isDelivered(folder: folder, fingerprint: fingerprint) { return }

        guard let infos = try? await LibraryScanner.scan(directory: folder), !infos.isEmpty else { return }
        let draft = AlbumDraft.from(folder: folder, infos: infos)
        let snapshot = draft.snapshot()
        let quality = draft.dsdQuality
        // Собираем манифест вне главного потока. Для DSD сначала конвертируем в FLAC
        // (staging) — тогда папка-раздачи = staging; без ffmpeg молча пропускаем
        // (автоочередь — best-effort). Возвращаем и альбом, и папку-раздачи.
        let built = await Task.detached(priority: .utility) {
            () -> (album: ManifestAlbum, sourceFolder: URL)? in
            let prepared: ManifestBuilder.DraftSnapshot
            if DSDStaging.containsDSD(snapshot) {
                guard let ffmpeg = FFmpegLocator.find(),
                      let staged = try? DSDStaging.materialize(snapshot, quality: quality, ffmpeg: ffmpeg)
                else { return nil }
                prepared = staged
            } else {
                prepared = snapshot
            }
            guard let album = try? ManifestBuilder.buildAlbum(from: prepared) else { return nil }
            return (album, prepared.sourceFolder)
        }.value
        guard let built else { return }
        // Идемпотентно: не дублируем альбом, уже стоящий в очереди (по albumId).
        // Учёт доставки — по оригиналу (`folder`), даже если раздаём из staging.
        if !queue.albums.contains(where: { $0.id == built.album.id }) {
            queue.enqueue(QueuedAlbum(manifestAlbum: built.album,
                                      sourceFolder: built.sourceFolder,
                                      deliveredKeyFolder: folder))
        }
    }

    /// Путь файла автоочереди (`~/.zver-autoqueue`): по строке на папку-альбом.
    static var autoqueuePath: String {
        NSString(string: "~/.zver-autoqueue").expandingTildeInPath
    }

    /// Канонический путь папки (устойчив к `..`/симлинкам/хвостовому слэшу) — как
    /// ключ `DeliveredStore`, чтобы сравнение строк автоочереди было надёжным.
    static func canonicalPath(_ folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Убирает папку из `~/.zver-autoqueue` (по каноническому пути). Зовётся, когда
    /// телефон ПОДТВЕРДИЛ доставку: доставленный альбом физически исчезает из списка-
    /// источника и больше НИКОГДА не всплывёт в очереди при следующих запусках —
    /// независимо от отпечатка/mtime. Это и есть гарантия «синканул → пропало».
    /// Не найдено (ручной дроп) — no-op. Атомарная перезапись файла.
    static func removeFromAutoqueue(folder: URL) {
        let path = autoqueuePath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let newContent = autoqueueContent(content, removing: folder)
        guard newContent != content else { return }
        try? newContent.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Чистая логика удаления: возвращает содержимое `~/.zver-autoqueue` без строк,
    /// чей канонический путь совпадает с `folder` (пустые строки тоже отсеиваются).
    /// Вынесена из ``removeFromAutoqueue(folder:)`` для юнит-тестов без ФС.
    static func autoqueueContent(_ content: String, removing folder: URL) -> String {
        let target = canonicalPath(folder)
        let kept = content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && canonicalPath(URL(fileURLWithPath: $0)) != target }
        return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n"
    }

    /// Читает список папок из `~/.zver-autoqueue` (по строке на путь) и ставит их
    /// в очередь по очереди. Nonisolated-обёртка, кидающая работу на `@MainActor`.
    static func runStartupAutoqueue(queue: OutgoingQueue, delivered: DeliveredStore) {
        Task { @MainActor in
            guard let list = try? String(contentsOfFile: autoqueuePath, encoding: .utf8) else { return }
            let folders = list.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for p in folders {
                await enqueueFolder(URL(fileURLWithPath: p), into: queue, delivered: delivered)
            }
        }
    }
}

/// App-делегат: запускает автосинк после `applicationDidFinishLaunching` —
/// надёжнее, чем `.task` окна, чьё окно может быть закрыто.
final class ZverAppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var onLaunch: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        ZverAppDelegate.onLaunch?()
    }
}

extension AlbumDraft {
    /// Снимок данных модели для безопасной передачи на фоновую очередь. Internal —
    /// используется и ручным enqueue (`SyncTabView`), и автоочередью (`MacEnqueue`).
    func snapshot() -> ManifestBuilder.DraftSnapshot {
        ManifestBuilder.DraftSnapshot(
            albumId: albumId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: artist,
            year: parsedYear,
            sourceFolder: sourceFolder,
            artworkFileName: artworkFileName,
            playlistFileName: playlistFileName,
            extraFileNames: extraFileNames,
            tracks: tracks.map { track in
                ManifestBuilder.DraftSnapshot.TrackSnapshot(
                    fileURL: track.fileURL,
                    fileName: track.fileName,
                    relativePath: track.relativePath,
                    fileExtension: track.fileExtension,
                    title: track.title,
                    artist: track.artist,
                    album: title,
                    trackNumber: track.parsedTrackNumber,
                    discNumber: track.discNumber,
                    year: parsedYear,
                    duration: track.duration,
                    sampleRate: track.sampleRate,
                    bitDepth: track.bitDepth
                )
            }
        )
    }
}
