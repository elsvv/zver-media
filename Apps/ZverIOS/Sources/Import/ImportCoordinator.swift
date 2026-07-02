import Foundation
import ZverTransport

/// Оркестратор импорта альбомов с Мака: манифест → дельта-план → очередь загрузок
/// с докачкой и sha-сверкой → раскладка в библиотеку → рескан каталога (reconcile
/// подхватывает правки из sidecar) → `POST /confirm` Маку.
///
/// `@MainActor`: публикует состояние импорта для SwiftUI. Тяжёлая работа (загрузка,
/// хеширование, запись на диск) идёт в `DownloadEngine` на фоновых тасках; в UI
/// возвращаемся через `@MainActor`. Идемпотентно: повторный запуск продолжает с
/// места — `SyncPlanner` пропускает совпавшие файлы, частичные докачиваются.
@MainActor
final class ImportCoordinator: ObservableObject {
    /// Фаза импорта одного альбома.
    enum AlbumPhase: Equatable {
        case waiting
        case downloading(progress: Double)
        case finalizing
        case done
        case failed(String)
    }

    /// Состояние импорта альбома для UI (id, заголовок, фаза, прогресс).
    struct AlbumImport: Identifiable, Equatable {
        let id: String
        let title: String
        let totalFiles: Int
        var phase: AlbumPhase
    }

    /// Общая фаза экрана импорта.
    enum Phase: Equatable {
        case idle
        case running
        case finished
        case failed(String)
    }

    @Published private(set) var albums: [AlbumImport] = []
    @Published private(set) var phase: Phase = .idle

    private let manifest: SyncManifest
    private let engine: DownloadEngine
    private let confirm: @Sendable (String) async throws -> Void
    /// Рескан библиотеки после раскладки альбома (обёртка над `LibraryStore.refresh`).
    private let rescan: @MainActor () async -> Void
    /// Считает sha уже лежащих локально файлов по путям из манифеста.
    private let localShas: @Sendable () async -> [String: String]

    private var isRunning = false

    init(
        manifest: SyncManifest,
        engine: DownloadEngine,
        confirm: @escaping @Sendable (String) async throws -> Void,
        rescan: @escaping @MainActor () async -> Void,
        localShas: @escaping @Sendable () async -> [String: String]
    ) {
        self.manifest = manifest
        self.engine = engine
        self.confirm = confirm
        self.rescan = rescan
        self.localShas = localShas
    }

    /// Считает локальные sha по уже лежащим файлам альбомов манифеста (для
    /// дельта-плана). Чтение/хеширование — вне главного потока. Файлы, которых нет,
    /// в карту не попадают (план тогда поставит их на докачку).
    nonisolated static func computeLocalShas(manifest: SyncManifest, engine: DownloadEngine) -> [String: String] {
        var shas: [String: String] = [:]
        for album in manifest.albums {
            for track in album.tracks {
                let url = engine.finalURL(albumId: album.id, fileName: track.fileName)
                if FileManager.default.fileExists(atPath: url.path),
                   let hash = try? Sha256.hash(fileURL: url) {
                    shas[relativePath(albumId: album.id, fileName: track.fileName)] = hash
                }
            }
            if let artwork = album.artwork {
                let url = engine.finalURL(albumId: album.id, fileName: artwork.fileName)
                if FileManager.default.fileExists(atPath: url.path),
                   let hash = try? Sha256.hash(fileURL: url) {
                    shas[relativePath(albumId: album.id, fileName: artwork.fileName)] = hash
                }
            }
            if let playlist = album.playlist {
                let url = engine.finalURL(albumId: album.id, fileName: playlist.fileName)
                if FileManager.default.fileExists(atPath: url.path),
                   let hash = try? Sha256.hash(fileURL: url) {
                    shas[relativePath(albumId: album.id, fileName: playlist.fileName)] = hash
                }
            }
        }
        return shas
    }

    /// Число раздаваемых файлов альбома: треки + обложка + плейлист (если есть).
    private nonisolated static func fileCount(of album: ManifestAlbum) -> Int {
        album.tracks.count + (album.artwork == nil ? 0 : 1) + (album.playlist == nil ? 0 : 1)
    }

    /// Относительный путь раздачи `"<albumId>/<fileName>"` — ключ карты sha,
    /// согласованный с `SyncPlanner` (его внутренний хелпер не public).
    private nonisolated static func relativePath(albumId: String, fileName: String) -> String {
        "\(albumId)/\(fileName)"
    }

    /// Запускает импорт всей очереди манифеста. Повторный вызов во время работы —
    /// no-op. По завершении каждого полностью разложенного и сверенного альбома —
    /// рескан каталога и `POST /confirm`.
    func start() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        phase = .running

        // Дельта-план: что докачать, какие альбомы уже целиком на месте.
        let local = await localShas()
        let plan = SyncPlanner.plan(manifest: manifest, localShasByPath: local)

        // Заготавливаем состояние UI по всем альбомам манифеста.
        albums = manifest.albums.map { album in
            let total = Self.fileCount(of: album)
            let isComplete = plan.alreadyComplete.contains(album.id)
            return AlbumImport(
                id: album.id,
                title: album.title,
                totalFiles: total,
                phase: isComplete ? .finalizing : .waiting
            )
        }

        let fetchByAlbum = Dictionary(grouping: plan.toFetch, by: { $0.albumId })
        var anyFailure = false

        // Последовательно по альбомам: ровный прогресс, предсказуемая нагрузка на
        // сеть/диск. confirm шлём только когда ВСЕ файлы альбома сверены.
        for album in manifest.albums {
            let planned = fetchByAlbum[album.id] ?? []
            do {
                try await importAlbum(album, planned: planned)
                await rescan()
                try await confirm(album.id)
                setPhase(.done, for: album.id)
            } catch is CancellationError {
                setPhase(.failed("Импорт отменён."), for: album.id)
                anyFailure = true
            } catch {
                setPhase(.failed(Self.message(for: error)), for: album.id)
                anyFailure = true
            }
        }

        phase = anyFailure ? .failed("Не все альбомы импортированы. Повторите попытку.") : .finished
    }

    /// Доли готовности качающихся файлов по альбому (`albumId` → `fileName` →
    /// 0...1). Живёт на MainActor: прогресс-колбэк (с сетевой очереди) обновляет её
    /// только внутри `Task { @MainActor }`, не пересекая Sendable-границу мутабельным
    /// локальным состоянием (краш-класс Swift 6).
    private var perFileProgress: [String: [String: Double]] = [:]

    /// Качает и раскладывает все запланированные файлы альбома, затем пишет sidecar.
    /// `confirm`/рескан — на вызывающей стороне (после полной сверки).
    private func importAlbum(_ album: ManifestAlbum, planned: [PlannedFile]) async throws {
        let albumId = album.id
        let total = Self.fileCount(of: album)

        // Уже лежащие и сверенные файлы (не в плане) считаем готовыми для прогресса.
        let completedAlready = total - planned.count
        perFileProgress[albumId] = [:]

        if planned.isEmpty {
            // Альбом уже целиком на месте: только sidecar + переход к confirm.
            setPhase(.finalizing, for: albumId)
            try engine.writeSidecar(for: album)
            engine.pruneStaleFiles(for: album)
            return
        }

        updateDownloadingPhase(albumId: albumId, completed: completedAlready, total: total)

        for file in planned {
            let key = file.fileName
            try await engine.fetchFile(file) { [weak self] fraction in
                // Колбэк прогресса может прийти с сетевой очереди — на MainActor.
                // Через границу переносим только Sendable-значения.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.perFileProgress[albumId, default: [:]][key] = fraction
                    self.updateDownloadingPhase(albumId: albumId, completed: completedAlready, total: total)
                }
            }
            perFileProgress[albumId, default: [:]][key] = 1.0
            updateDownloadingPhase(albumId: albumId, completed: completedAlready, total: total)
        }

        // Все файлы альбома разложены и сверены: материализуем правки в sidecar
        // и убираем устаревшие файлы (напр. плоские до реорганизации в CD-папки).
        setPhase(.finalizing, for: albumId)
        try engine.writeSidecar(for: album)
        engine.pruneStaleFiles(for: album)
    }

    /// Пересчитывает и публикует фазу `.downloading` по накопленному прогрессу.
    private func updateDownloadingPhase(albumId: String, completed: Int, total: Int) {
        let perFile = perFileProgress[albumId] ?? [:]
        setPhase(.downloading(progress: progressFraction(completed: completed, total: total, perFile: perFile)),
                 for: albumId)
    }

    /// Доля готовности альбома: (готовые файлы + сумма долей качающихся) / всего.
    private func progressFraction(completed: Int, total: Int, perFile: [String: Double]) -> Double {
        guard total > 0 else { return 1.0 }
        let inProgress = perFile.values.reduce(0, +)
        return min(1.0, (Double(completed) + inProgress) / Double(total))
    }

    private func setPhase(_ phase: AlbumPhase, for albumId: String) {
        guard let idx = albums.firstIndex(where: { $0.id == albumId }) else { return }
        albums[idx].phase = phase
    }

    /// Человекочитаемое RU-сообщение по типу ошибки импорта.
    private static func message(for error: Error) -> String {
        switch error {
        case let DownloadEngine.EngineError.checksumMismatch(fileName):
            return "Файл «\(fileName)» скачался с ошибкой (не сошлась контрольная сумма)."
        case DownloadEngine.EngineError.fileSystem:
            return "Не удалось сохранить файлы на устройство."
        case MacSyncClient.ClientError.timeout:
            return "Мак перестал отвечать. Проверьте соединение."
        case MacSyncClient.ClientError.connectionFailed:
            return "Соединение с Маком прервалось."
        case let MacSyncClient.ClientError.httpStatus(code):
            return "Мак вернул ошибку (\(code))."
        default:
            return "Импорт не удался. Повторите попытку."
        }
    }
}
