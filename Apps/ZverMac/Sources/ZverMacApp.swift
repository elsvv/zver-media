import SwiftUI
import UniformTypeIdentifiers
import ZverMetadata
import ZverTransport

/// Mac-компаньон Zver Media.
///
/// Живёт в меню-баре (`LSUIElement`); главное окно — импорт альбомов:
/// drag-drop папки → превью/редактор → исходящая очередь. Сетевая раздача
/// (сервер + Bonjour + pairing) — S3-9, здесь только каркас.
@main
struct ZverMacApp: App {
    @NSApplicationDelegateAdaptor(ZverAppDelegate.self) private var appDelegate
    @StateObject private var queue: OutgoingQueue
    @StateObject private var dropController = DropController()
    /// Координатор сетевой раздачи (сервер + Bonjour + pairing). Создаётся поверх
    /// той же очереди, что и UI: стартует сервер при непустой очереди.
    @StateObject private var server: ServerCoordinator
    /// Координатор пульта (этап 5): browse `_zver._tcp svc=remote` → WS-клиент к
    /// iPhone → приём состояния/библиотеки, отправка команд. Живёт всё время
    /// работы приложения; browse реально стартует при открытии окна «Пульт».
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
        Window("Zver Media — Синк", id: "main") {
            ImportWindow(queue: queue, dropController: dropController, server: server)
        }
        .defaultSize(width: 760, height: 560)

        Window("Пульт", id: "remote") {
            RemoteControlView(coordinator: remote)
        }
        .defaultSize(width: 440, height: 600)

        MenuBarExtra("Zver Media", systemImage: "music.note.house") {
            MenuBarContent(queue: queue, server: server)
        }
    }
}

/// Главное окно импорта: слева очередь, справа дроп-зона/превью.
private struct ImportWindow: View {
    @ObservedObject var queue: OutgoingQueue
    @ObservedObject var dropController: DropController
    @ObservedObject var server: ServerCoordinator

    /// Подсветка дроп-зоны при наведении папки.
    @State private var isTargeted = false

    var body: some View {
        HSplitView {
            QueueView(queue: queue, server: server)
                .frame(minWidth: 240, idealWidth: 280)

            ZStack {
                if let draft = dropController.draft {
                    AlbumPreviewView(
                        draft: draft,
                        onEnqueue: { await enqueue(draft: draft) },
                        onCancel: { dropController.clear() }
                    )
                } else {
                    DropZone(
                        isTargeted: isTargeted,
                        isScanning: dropController.isScanning,
                        error: dropController.lastError
                    )
                }
            }
            .frame(minWidth: 420)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    /// Drag-drop папки → скан → черновик. Парсинг провайдеров и скан — async,
    /// публикация черновика — на `@MainActor` внутри `DropController`.
    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            guard let folder = await DropController.firstFolderURL(from: providers)
            else { return }
            await dropController.importFolder(folder)
        }
    }

    /// «В очередь»: снимает данные с `@MainActor`-модели, собирает манифест с
    /// хешированием файлов ВНЕ главного потока, затем публикует в очередь на
    /// `@MainActor`. После успеха очищает черновик и возвращает nil; на ошибке
    /// возвращает текст (RU) — `AlbumPreviewView` сбросит индикацию и покажет его,
    /// черновик остаётся для повторной попытки.
    private func enqueue(draft: AlbumDraft) async -> String? {
        let snapshot = draft.snapshot()
        let keyFolder = draft.sourceFolder   // оригинал для учёта доставки

        // DSD-альбом: сконвертировать `.dsf` → FLAC в staging ДО сборки манифеста.
        // Прогресс капаем в черновик (футер превью), исходную папку не трогаем.
        let prepared: ManifestBuilder.DraftSnapshot
        if DSDStaging.containsDSD(snapshot) {
            guard let ffmpeg = FFmpegLocator.find() else {
                return "Не найден ffmpeg (нужен для DSD). Установите: brew install ffmpeg"
            }
            let quality = draft.dsdQuality
            let total = snapshot.tracks.filter { $0.fileExtension == "dsf" }.count
            let generation = draft.beginConversion(total: total)
            do {
                prepared = try await Task.detached(priority: .userInitiated) {
                    try DSDStaging.materialize(snapshot, quality: quality, ffmpeg: ffmpeg) { done, total in
                        Task { @MainActor in
                            draft.reportConversion(done: done, total: total, generation: generation)
                        }
                    }
                }.value
            } catch {
                draft.endConversion()
                return (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось сконвертировать DSD в FLAC."
            }
            draft.endConversion()
        } else {
            prepared = snapshot
        }

        let album = await Task.detached(priority: .userInitiated) {
            () -> QueuedAlbum.BuildResult in
            do {
                let manifestAlbum = try ManifestBuilder.buildAlbum(from: prepared)
                return .success(manifestAlbum)
            } catch {
                return .failure("Не удалось подготовить альбом к отправке.")
            }
        }.value

        switch album {
        case .success(let manifestAlbum):
            queue.enqueue(QueuedAlbum(
                manifestAlbum: manifestAlbum,
                sourceFolder: prepared.sourceFolder,
                deliveredKeyFolder: keyFolder
            ))
            dropController.clear()
            return nil
        case .failure(let message):
            // Черновик оставляем, чтобы пользователь мог повторить отправку.
            return message
        }
    }
}

extension QueuedAlbum {
    /// Результат фоновой сборки манифеста (Sendable для перехода с detached-таски).
    enum BuildResult: Sendable {
        case success(ManifestAlbum)
        case failure(String)
    }
}

/// Пустая дроп-зона / индикатор скана / ошибка.
private struct DropZone: View {
    let isTargeted: Bool
    let isScanning: Bool
    let error: String?

    var body: some View {
        VStack(spacing: 14) {
            if isScanning {
                ProgressView()
                Text("Читаю папку альбома…")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 52))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                Text("Перетащите сюда папку альбома")
                    .font(.title3)
                Text("Метаданные можно отредактировать перед отправкой — исходные файлы не меняются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(20)
        )
    }
}

/// Содержимое меню-бара: краткий статус очереди.
private struct MenuBarContent: View {
    @ObservedObject var queue: OutgoingQueue
    @ObservedObject var server: ServerCoordinator
    /// Открывает/фокусирует главное окно даже если оно было закрыто
    /// (LSUIElement-агент: `NSApp.activate` закрытую SwiftUI-сцену не воскрешает).
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
        Button("Открыть пульт") {
            openWindow(id: "remote")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Открыть окно синка") {
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
/// надёжнее, чем `.task` окна у menu-bar-агента, чьё окно может быть закрыто.
final class ZverAppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var onLaunch: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        ZverAppDelegate.onLaunch?()
    }
}

private extension AlbumDraft {
    /// Снимок данных модели для безопасной передачи на фоновую очередь.
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
