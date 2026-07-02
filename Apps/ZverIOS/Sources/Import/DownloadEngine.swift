import Foundation
import ZverMetadata
import ZverTransport

/// Движок докачиваемой загрузки и атомарной раскладки альбома в библиотеку.
///
/// Поток на один файл: качаем во временный `.partial` (продолжая с уже скачанных
/// байт через `Range`) → сверяем sha256 против манифеста → атомарно перекладываем
/// (`moveItem`) в `Documents/Library/<albumId>/<fileName>`. На несовпадении sha —
/// удаляем частичный файл и перекачиваем целиком (ретрай раз). По завершении всех
/// файлов альбома пишем sidecar `album.zvermeta.json` из правленых полей манифеста.
///
/// Чистая логика (sha-сверка, дельта-план, построение sidecar-overlay) — в
/// `ZverTransport`/`ZverMetadata` под TDD; здесь — app-glue над ФС и `RangeDownloading`,
/// проверяемый компиляцией (рантайма нет). `Sha256`/`SyncPlanner` потребляются как есть.
struct DownloadEngine {
    /// Корневая папка библиотеки на телефоне (`Documents/Library`). Скан
    /// `LibraryStore` рекурсивно её обходит, reconcile подхватывает правки sidecar.
    let libraryRoot: URL
    /// Папка для частичных загрузок (`.partial`-файлы вне скана библиотеки).
    let stagingRoot: URL
    let downloader: RangeDownloading
    let token: String

    enum EngineError: Error, Sendable {
        /// Sha256 скачанного файла не совпал с манифестом даже после ретрая.
        case checksumMismatch(fileName: String)
        /// Не удалось создать каталог/переместить файл.
        case fileSystem(underlying: Error)
    }

    /// Папка альбома в библиотеке: `Documents/Library/<albumId>/`.
    func albumDirectory(albumId: String) -> URL {
        libraryRoot.appendingPathComponent(albumId, isDirectory: true)
    }

    /// Финальный путь файла: `Documents/Library/<albumId>/<fileName>`.
    func finalURL(albumId: String, fileName: String) -> URL {
        albumDirectory(albumId: albumId).appendingPathComponent(fileName)
    }

    /// Скачивает один запланированный файл с докачкой и sha-сверкой, кладёт на место.
    ///
    /// Идемпотентно: если финальный файл уже лежит и его sha совпал — скачивание
    /// пропускается. Иначе докачивает частичный `.partial` (с уже скачанной позиции),
    /// сверяет sha, на несовпадении перекачивает целиком (одна повторная попытка).
    ///
    /// - `progress` отдаёт долю готовности файла 0...1 (для UI). Может приходить с
    ///   сетевой очереди — потребитель сам прыгает на MainActor.
    func fetchFile(
        _ planned: PlannedFile,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let final = finalURL(albumId: planned.albumId, fileName: planned.fileName)

        // Идемпотентность: готовый и верный файл — ничего не качаем.
        if FileManager.default.fileExists(atPath: final.path),
           (try? Sha256.hash(fileURL: final)) == planned.sha256 {
            progress(1.0)
            return
        }

        try ensureDirectory(albumDirectory(albumId: planned.albumId))
        // fileName может нести подпапку-диск (`CD1/01 - x.flac`) — создаём её под
        // альбомом, иначе атомарный moveItem в финальный путь упадёт.
        try ensureDirectory(final.deletingLastPathComponent())
        try ensureDirectory(stagingRoot)
        // Имя партиала держим ПЛОСКИМ: `/` из относительного пути заменяем, чтобы
        // не плодить подпапки в staging (и не ловить «нет каталога» при записи).
        let partialName = "\(planned.albumId)__\(planned.fileName).partial"
            .replacingOccurrences(of: "/", with: "_")
        let partial = stagingRoot.appendingPathComponent(partialName)

        let expected = Int64(planned.fileSize)
        let reportProgress: @Sendable (Int64) -> Void = { onDisk in
            guard expected > 0 else { progress(0); return }
            progress(min(1.0, Double(onDisk) / Double(expected)))
        }

        // Стартовая позиция докачки = размер уже скачанного частичного файла.
        var resumeFrom = partialSize(partial)
        var verifiedURL: URL?

        // Частичный файл уже >= ожидаемого размера: докачка дала бы `Range` за концом
        // файла → сервер вернёт 416, и без обработки это вечный затык (партиал не
        // удаляется, каждый ретрай повторяет тот же запрос). Сверяем имеющийся файл
        // напрямую: sha совпал — он и есть готовый; нет (устаревший/пересжатый) —
        // выкидываем и качаем с нуля.
        if expected > 0, resumeFrom >= expected {
            if (try? Sha256.hash(fileURL: partial)) == planned.sha256 {
                verifiedURL = partial
            } else {
                try? FileManager.default.removeItem(at: partial)
                resumeFrom = 0
            }
        }

        // Докачка от текущей позиции. 416 (сервер отверг Range — устаревший партиал)
        // трактуем как «перекачать с нуля», а не как фатальную ошибку.
        if verifiedURL == nil {
            do {
                verifiedURL = try await downloadAndVerify(
                    planned: planned,
                    partial: partial,
                    resumeFrom: resumeFrom,
                    progress: reportProgress
                )
            } catch let MacSyncClient.ClientError.httpStatus(code) where code == 416 {
                verifiedURL = nil
            }
        }

        // Sha не совпал ИЛИ сервер отверг Range — частичный файл битый/устаревший:
        // удаляем и качаем целиком с нуля (одна повторная попытка).
        if verifiedURL == nil {
            try? FileManager.default.removeItem(at: partial)
            resumeFrom = 0
            verifiedURL = try await downloadAndVerify(
                planned: planned,
                partial: partial,
                resumeFrom: resumeFrom,
                progress: reportProgress
            )
        }

        guard let ready = verifiedURL else {
            try? FileManager.default.removeItem(at: partial)
            throw EngineError.checksumMismatch(fileName: planned.fileName)
        }

        // Атомарная раскладка: проверенный временный → финальный путь.
        do {
            if FileManager.default.fileExists(atPath: final.path) {
                try FileManager.default.removeItem(at: final)
            }
            try FileManager.default.moveItem(at: ready, to: final)
        } catch {
            throw EngineError.fileSystem(underlying: error)
        }
        progress(1.0)
    }

    /// Качает в `partial` (резюм с `resumeFrom`), сверяет sha. Возвращает URL
    /// готового файла при совпадении, `nil` — при несовпадении (вызывающий решает
    /// перекачать). Бросает только на сетевых/файловых сбоях.
    private func downloadAndVerify(
        planned: PlannedFile,
        partial: URL,
        resumeFrom: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL? {
        _ = try await downloader.download(
            albumId: planned.albumId,
            fileName: planned.fileName,
            token: token,
            resumeFrom: resumeFrom,
            destination: partial,
            progress: progress
        )
        let actual = try Sha256.hash(fileURL: partial)
        return actual == planned.sha256 ? partial : nil
    }

    /// Пишет sidecar `album.zvermeta.json` в папку альбома из правленых полей
    /// манифеста. Только после раскладки всех файлов альбома: `LibraryScanner`
    /// наложит overlay при следующем рескане (reconcile подхватит правки).
    func writeSidecar(for album: ManifestAlbum) throws {
        let sidecar = Self.makeSidecar(from: album)
        let url = albumDirectory(albumId: album.id).appendingPathComponent(AlbumSidecar.fileName)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sidecar)
            try data.write(to: url, options: .atomic)
        } catch {
            throw EngineError.fileSystem(underlying: error)
        }
    }

    /// Строит `AlbumSidecar` из манифеста: правленые на Маке поля треков становятся
    /// `TrackOverride` (ключ — `fileName`), обложка альбома — `artworkFileName`.
    ///
    /// Чистая трансформация app-уровня (мост `ZverTransport.ManifestAlbum` →
    /// `ZverMetadata.AlbumSidecar`), не выносится в пакет: зависела бы сразу от двух
    /// пакетов, которые друг о друге не знают. Проверяется компиляцией.
    static func makeSidecar(from album: ManifestAlbum) -> AlbumSidecar {
        var tracks: [String: TrackOverride] = [:]
        for track in album.tracks {
            tracks[track.fileName] = TrackOverride(
                title: track.title,
                artist: track.artist,
                album: track.album,
                year: track.year,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber
            )
        }
        return AlbumSidecar(
            version: 1,
            artworkFileName: album.artwork?.fileName,
            tracks: tracks
        )
    }

    // MARK: - Файловые помощники

    /// Размер уже скачанного частичного файла (0, если файла нет) — позиция докачки.
    private func partialSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw EngineError.fileSystem(underlying: error)
        }
    }
}
