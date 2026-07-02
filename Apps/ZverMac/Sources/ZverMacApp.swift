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
        _queue = StateObject(wrappedValue: queue)
        _server = StateObject(wrappedValue: ServerCoordinator(queue: queue))
        // Программный автосинк: после старта читаем ~/.zver-autoqueue (список папок-
        // альбомов, по строке на путь) и ставим их в очередь без drag-drop —
        // «агент кладёт список → музыка в очереди, на телефоне один тап Импорт».
        ZverAppDelegate.onLaunch = { MacEnqueue.runStartupAutoqueue(queue: queue) }
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
        let album = await Task.detached(priority: .userInitiated) {
            () -> QueuedAlbum.BuildResult in
            do {
                let manifestAlbum = try ManifestBuilder.buildAlbum(from: snapshot)
                return .success(manifestAlbum)
            } catch {
                return .failure("Не удалось подготовить альбом к отправке.")
            }
        }.value

        switch album {
        case .success(let manifestAlbum):
            queue.enqueue(QueuedAlbum(
                manifestAlbum: manifestAlbum,
                sourceFolder: snapshot.sourceFolder
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
    static func enqueueFolder(_ folder: URL, into queue: OutgoingQueue) async {
        guard let infos = try? await LibraryScanner.scan(directory: folder), !infos.isEmpty else { return }
        let draft = AlbumDraft.from(folder: folder, infos: infos)
        let snapshot = draft.snapshot()
        let album = await Task.detached(priority: .utility) { () -> ManifestAlbum? in
            try? ManifestBuilder.buildAlbum(from: snapshot)
        }.value
        guard let album else { return }
        // Идемпотентно: не дублируем альбом, уже стоящий в очереди (по albumId).
        if !queue.albums.contains(where: { $0.id == album.id }) {
            queue.enqueue(QueuedAlbum(manifestAlbum: album, sourceFolder: snapshot.sourceFolder))
        }
    }

    /// Читает список папок из `~/.zver-autoqueue` (по строке на путь) и ставит их
    /// в очередь по очереди. Nonisolated-обёртка, кидающая работу на `@MainActor`.
    static func runStartupAutoqueue(queue: OutgoingQueue) {
        Task { @MainActor in
            let path = NSString(string: "~/.zver-autoqueue").expandingTildeInPath
            guard let list = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let folders = list.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for p in folders {
                await enqueueFolder(URL(fileURLWithPath: p), into: queue)
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
