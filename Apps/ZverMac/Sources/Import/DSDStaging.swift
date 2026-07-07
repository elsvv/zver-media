import AVFoundation
import Foundation

/// Материализует DSD-альбом в раздаваемый FLAC, НЕ трогая исходную папку.
///
/// Раздача читает байты из `sourceFolder + relativePath`, а хеш манифеста
/// считается по тем же файлам — значит, чтобы отдать телефону FLAC вместо `.dsf`,
/// достаточно один раз сконвертировать альбом в app-managed staging-папку и
/// поставить в очередь ЕЁ как источник. `SyncHost`/`FileServer`/`ManifestBuilder`
/// при этом не меняются. Дропнутая пользователем папка остаётся неизменной
/// (иммутабельность): из неё только читают.
///
/// Не-DSD альбомы проходят насквозь без изменений (раздаются прямо из источника).
enum DSDStaging {
    /// Есть ли в альбоме хоть один DSD-трек (`.dsf`).
    static func containsDSD(_ snapshot: ManifestBuilder.DraftSnapshot) -> Bool {
        snapshot.tracks.contains { $0.fileExtension == "dsf" }
    }

    /// Корень staging: `~/Library/Application Support/ZverMac/staging/`.
    static func stagingRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("ZverMac/staging", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Лежит ли URL внутри staging (для очистки после доставки).
    static func isStaged(_ url: URL) -> Bool {
        guard let root = try? stagingRoot() else { return false }
        return url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Удаляет staging-папку альбома (после `confirm` от телефона — сконвертированные
    /// FLAC больше не нужны). Только внутри staging; вне его — no-op (безопасность).
    static func cleanup(_ url: URL) {
        guard isStaged(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Сносит ВЕСЬ staging. Зовётся при старте приложения: очередь в памяти пуста,
    /// значит любые staging-папки осиротели с прошлой сессии (незавершённые
    /// конвертации, недоставленные/снятые вручную альбомы) — hi-res FLAC зависли бы
    /// на диске (гигабайты). Автоочередь пере-материализует то, что реально нужно.
    static func sweepAll() {
        guard let root = try? stagingRoot(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else { return }
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    /// Конвертирует DSD-треки альбома в FLAC (в staging) и возвращает НОВЫЙ снимок
    /// с источником-staging и треками-FLAC. Для не-DSD альбома возвращает снимок
    /// без изменений. `progress(done, total)` — по завершении каждого DSD-трека.
    /// Синхронный и блокирующий (ffmpeg) — зовите с фоновой очереди.
    static func materialize(_ snapshot: ManifestBuilder.DraftSnapshot,
                            quality: DSDQuality,
                            ffmpeg: URL,
                            progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) throws -> ManifestBuilder.DraftSnapshot {
        guard containsDSD(snapshot) else { return snapshot }
        let fm = FileManager.default
        let dir = try stagingRoot().appendingPathComponent(safeName(snapshot.albumId), isDirectory: true)
        // Свежая раздача: очищаем прежний staging этого альбома (идемпотентность).
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let total = snapshot.tracks.filter { $0.fileExtension == "dsf" }.count
        var done = 0
        var newTracks: [ManifestBuilder.DraftSnapshot.TrackSnapshot] = []
        newTracks.reserveCapacity(snapshot.tracks.count)
        // Уникализируем выходные пути: `x.dsf`→`x.flac` мог бы совпасть с соседним
        // `x.flac`/`x.m4a` в смешанном альбоме (редкость) — без этого один файл затёр
        // бы другой, а в манифесте вышло бы два трека на один путь (один звук потерян).
        var usedRelPaths: Set<String> = []

        do {
            for var track in snapshot.tracks {
                if track.fileExtension == "dsf" {
                    let base = (track.relativePath as NSString).deletingPathExtension
                    let outRel = uniqueRelPath(base + ".flac", used: &usedRelPaths)
                    let outURL = dir.appendingPathComponent(outRel)
                    try fm.createDirectory(at: outURL.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try DSDTranscoder.transcode(dsf: track.fileURL, to: outURL,
                                                quality: quality, ffmpeg: ffmpeg)
                    // Точные частоту/длительность берём из готового FLAC (macOS читает
                    // FLAC). Бросит, если ffmpeg дал битый файл (0-код, но нечитаемый),
                    // — тогда мёртвый трек не уедет, ошибка всплывёт при импорте.
                    let probed = try probeFLAC(outURL, quality: quality)
                    track.fileURL = outURL
                    track.fileName = outURL.lastPathComponent
                    track.relativePath = outRel
                    track.fileExtension = "flac"
                    track.sampleRate = probed.sampleRate
                    track.bitDepth = probed.bitDepth
                    track.duration = probed.duration
                    newTracks.append(track)
                    done += 1
                    progress(done, total)
                } else {
                    // Не-DSD трек внутри DSD-альбома (редкость) — копируем как есть,
                    // чтобы весь альбом раздавался единообразно из staging.
                    let outRel = uniqueRelPath(track.relativePath, used: &usedRelPaths)
                    let outURL = dir.appendingPathComponent(outRel)
                    try fm.createDirectory(at: outURL.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try? fm.removeItem(at: outURL)
                    try fm.copyItem(at: track.fileURL, to: outURL)
                    track.fileURL = outURL
                    track.fileName = outURL.lastPathComponent
                    track.relativePath = outRel
                    newTracks.append(track)
                }
            }

            var out = snapshot
            out.sourceFolder = dir
            out.tracks = newTracks
            out.artworkFileName = copyCompanion(snapshot.artworkFileName, from: snapshot.sourceFolder, to: dir)
            // Плейлист/cue/log ссылаются на исходные `.dsf`-имена, которых в раздаче
            // уже нет (треки стали FLAC) — иначе телефон получил бы битые ссылки на
            // несуществующие файлы. Метаданные DSD берём из имени файла, деление на
            // диски здесь не нужно — companions для DSD-альбома не тащим.
            out.playlistFileName = nil
            out.extraFileNames = []
            return out
        } catch {
            // Сбой посреди альбома: частичный staging не оставляем (диск + чтобы
            // повторная попытка/чистка не наткнулась на недоделанное).
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    // MARK: - Помощники

    /// Точные частота/длительность готового FLAC + целевая разрядность. Бросает,
    /// если файл не открывается (валидный FLAC macOS открывает всегда, значит
    /// ошибка = битый транскод — мёртвый трек не должен уехать на телефон).
    private static func probeFLAC(_ url: URL, quality: DSDQuality) throws
        -> (sampleRate: Double, duration: Double, bitDepth: Int) {
        let file = try AVAudioFile(forReading: url)
        let sr = file.fileFormat.sampleRate
        let dur = sr > 0 ? Double(file.length) / sr : 0
        return (sr, dur, quality.bitDepth)
    }

    /// Возвращает `rel`, если путь ещё свободен; иначе добавляет « (2)», « (3)»…
    /// к имени файла (сохраняя каталог и расширение). Регистрирует занятые пути.
    private static func uniqueRelPath(_ rel: String, used: inout Set<String>) -> String {
        if used.insert(rel).inserted { return rel }
        let ns = rel as NSString
        let folder = ns.deletingLastPathComponent
        let ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let full = folder.isEmpty ? name : "\(folder)/\(name)"
            if used.insert(full).inserted { return full }
            n += 1
        }
    }

    /// Копирует файл-компаньон (обложка/плейлист/cue/log) в staging, сохраняя
    /// относительный путь. nil на входе или отсутствующий файл → nil (не раздаём).
    private static func copyCompanion(_ name: String?, from source: URL, to dir: URL) -> String? {
        guard let name else { return nil }
        let src = source.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let dst = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
            return name
        } catch {
            return nil
        }
    }

    /// Имя папки альбома в staging без разделителей пути.
    private static func safeName(_ s: String) -> String {
        let bad: Set<Character> = ["/", "\\", ":"]
        let cleaned = String(s.map { bad.contains($0) ? "_" : $0 })
        return cleaned.isEmpty ? "album" : cleaned
    }
}
