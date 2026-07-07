import SwiftUI
import UniformTypeIdentifiers
import ZverTransport

/// Вкладка «Синк»: панель «На iPhone» (запуск импорта с Мака + живой прогресс)
/// сверху, импорт-флоу (исходящая очередь + дроп-зона/превью) снизу.
///
/// Дроп-флоу — прежний каркас (drag-drop папки → скан → черновик → манифест →
/// очередь), сетевая раздача поднимается `ServerCoordinator` при непустой
/// очереди. Новое: при подключённом пульте кнопка «Импортировать на iPhone»
/// шлёт `startImport`, а `store.importStatus` рисует стадию/долю прямо на Маке.
struct SyncTabView: View {
    @ObservedObject var queue: OutgoingQueue
    @ObservedObject var dropController: DropController
    @ObservedObject var server: ServerCoordinator
    @ObservedObject var coordinator: RemoteClientCoordinator

    /// Подсветка дроп-зоны при наведении папки.
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            SyncToPhonePanel(coordinator: coordinator)
            Divider()
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
        .navigationTitle("Синк")
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

/// Панель «На iPhone»: запуск headless-импорта с Мака и живой прогресс из
/// `importStatus`. Пульт не подключён → подсказка (импорт с Мака требует
/// авторизованного пульта).
private struct SyncToPhonePanel: View {
    @ObservedObject var coordinator: RemoteClientCoordinator
    @ObservedObject var store: RemoteClientStore

    init(coordinator: RemoteClientCoordinator) {
        self.coordinator = coordinator
        self.store = coordinator.store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("На iPhone", systemImage: "iphone")
                    .font(.headline)
                Spacer()
                if coordinator.isConnected {
                    Button {
                        coordinator.startImport()
                    } label: {
                        Label("Импортировать на iPhone", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(isDownloading)
                }
            }
            if coordinator.isConnected {
                statusView
            } else {
                Text("Подключи пульт на вкладке «Пульт», чтобы запускать синк отсюда.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var isDownloading: Bool {
        store.importStatus?.phase == .downloading
    }

    @ViewBuilder
    private var statusView: some View {
        if let status = store.importStatus {
            switch status.phase {
            case .downloading:
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(max(status.fraction, 0), 1))
                    Text(downloadingLine(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .done:
                Label("Готово", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .failed:
                Text(status.message ?? "Импорт не удался.")
                    .font(.callout)
                    .foregroundStyle(.red)
            case .idle, .unknown:
                EmptyView()
            }
        } else {
            Text("Нажмите «Импортировать на iPhone», чтобы iPhone скачал очередь с Мака.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// «Качает: {albumTitle} · {completedAlbums} из {totalAlbums}».
    private func downloadingLine(_ status: RemoteImportStatus) -> String {
        var parts: [String] = []
        if let title = status.albumTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            parts.append("Качает: \(title)")
        } else {
            parts.append("Импорт…")
        }
        if status.totalAlbums > 0 {
            parts.append("\(status.completedAlbums) из \(status.totalAlbums)")
        }
        return parts.joined(separator: " · ")
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
