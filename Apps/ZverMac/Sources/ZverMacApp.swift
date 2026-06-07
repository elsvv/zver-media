import SwiftUI
import UniformTypeIdentifiers
import ZverTransport

/// Mac-компаньон Zver Media.
///
/// Живёт в меню-баре (`LSUIElement`); главное окно — импорт альбомов:
/// drag-drop папки → превью/редактор → исходящая очередь. Сетевая раздача
/// (сервер + Bonjour + pairing) — S3-9, здесь только каркас.
@main
struct ZverMacApp: App {
    @StateObject private var queue: OutgoingQueue
    @StateObject private var dropController = DropController()
    /// Координатор сетевой раздачи (сервер + Bonjour + pairing). Создаётся поверх
    /// той же очереди, что и UI: стартует сервер при непустой очереди.
    @StateObject private var server: ServerCoordinator

    init() {
        let queue = OutgoingQueue()
        _queue = StateObject(wrappedValue: queue)
        _server = StateObject(wrappedValue: ServerCoordinator(queue: queue))
    }

    var body: some Scene {
        Window("Zver Media — Синк", id: "main") {
            ImportWindow(queue: queue, dropController: dropController, server: server)
        }
        .defaultSize(width: 760, height: 560)

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
            tracks: tracks.map { track in
                ManifestBuilder.DraftSnapshot.TrackSnapshot(
                    fileURL: track.fileURL,
                    fileName: track.fileName,
                    fileExtension: track.fileExtension,
                    title: track.title,
                    artist: track.artist,
                    album: title,
                    trackNumber: track.parsedTrackNumber,
                    year: parsedYear,
                    duration: track.duration,
                    sampleRate: track.sampleRate,
                    bitDepth: track.bitDepth
                )
            }
        )
    }
}
