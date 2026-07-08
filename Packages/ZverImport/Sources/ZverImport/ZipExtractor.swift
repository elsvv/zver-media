import Foundation
import ZIPFoundation

/// Ошибки распаковки. Отделяют «архив вредоносный/битый» (жёсткий отказ) от
/// обычного пропуска чужих файлов (не ошибка — см. `ZipExtractor.extract`).
public enum ZipExtractError: Error, Equatable {
    /// Файл не открылся как zip или запись повреждена (битый CRC/данные).
    case unreadableArchive
    /// Запись пытается выйти за пределы папки назначения (zip-slip): относительный
    /// `..`, абсолютный путь или symlink. Ассоциированное — путь-нарушитель.
    case unsafeEntryPath(String)
    /// Суммарный распакованный размер превысил лимит (защита от zip-бомб).
    case sizeLimitExceeded(limit: Int64)
}

/// Безопасная распаковка zip во временную папку.
///
/// Гарантии:
/// - **zip-slip**: записи с `..`, абсолютным путём или symlink'и отклоняют весь
///   архив; плюс проверка «результат остаётся внутри назначения» как подстраховка.
/// - **белый список расширений**: наружу попадают только аудио (как в
///   `LibraryScanner`) и сопутствующие (обложки/плейлисты/cue/log/txt); всё
///   прочее (`.exe`, `.DS_Store`, `.nfo`, …) молча пропускается — это не ошибка,
///   реальные архивы полны мусора, а не повод завалить импорт.
/// - **лимит размера**: считаем заявленный распакованный размер по центральному
///   каталогу и отказываем до записи, если суммарно превышен лимит.
/// - **zip64**: поддержан самим ZIPFoundation (hi-res альбомы > 4 ГБ).
public enum ZipExtractor {
    /// Разрешённые расширения (без точки, нижний регистр). Аудио продублировано из
    /// `LibraryScanner` (тот держит список приватным) — если там появится формат,
    /// синхронизировать здесь.
    public static let allowedExtensions: Set<String> = [
        // аудио — как в LibraryScanner
        "flac", "m4a", "mp3", "wav", "aiff", "aif", "opus", "dsf",
        // обложки / сопутствующее
        "jpg", "jpeg", "png", "cue", "m3u", "m3u8", "log", "txt",
    ]

    /// Дефолтный лимит распакованного размера — 16 ГБ. Заведомо выше самого
    /// толстого hi-res бокс-сета (zip64), но отсекает абсурдные zip-бомбы.
    public static let defaultSizeLimit: Int64 = 16 * 1024 * 1024 * 1024

    /// Распаковывает `zipURL` в свежую уникальную подпапку `baseDirectory` и
    /// возвращает её URL. По умолчанию — системный tmp (тот же том, что нужен
    /// `AlbumImporter` для атомарного move в библиотеку).
    ///
    /// При любой ошибке частично распакованная папка удаляется — за собой не
    /// оставляем мусора. Пустые каталоги-записи и чужие расширения не переносятся.
    @discardableResult
    public static func extract(
        _ zipURL: URL,
        into baseDirectory: URL = FileManager.default.temporaryDirectory,
        sizeLimit: Int64 = defaultSizeLimit
    ) throws -> URL {
        let archive: Archive
        do {
            archive = try Archive(url: zipURL, accessMode: .read)
        } catch {
            throw ZipExtractError.unreadableArchive
        }

        let fm = FileManager.default
        let destination = baseDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try extractEntries(from: archive, into: destination, sizeLimit: sizeLimit)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return destination
    }

    // MARK: - Внутреннее

    private static func extractEntries(
        from archive: Archive, into destination: URL, sizeLimit: Int64
    ) throws {
        var totalSize: Int64 = 0
        for entry in archive {
            switch entry.type {
            case .directory:
                // Пустые каталоги не нужны — родители создаются при записи файлов.
                continue
            case .symlink:
                // Symlink в музыкальной библиотеке не бывает легитимным и является
                // отдельным вектором zip-slip (цель может указывать наружу).
                throw ZipExtractError.unsafeEntryPath(entry.path)
            case .file:
                break
            }

            let path = entry.path
            guard isSafeEntryPath(path) else {
                throw ZipExtractError.unsafeEntryPath(path)
            }

            // Чужое расширение — тихо пропускаем (не ошибка).
            let ext = (path as NSString).pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }

            let target = destination.appendingPathComponent(path)
            // Подстраховка: итоговый путь обязан остаться внутри назначения.
            guard isContained(target, in: destination) else {
                throw ZipExtractError.unsafeEntryPath(path)
            }

            totalSize += Int64(clamping: entry.uncompressedSize)
            guard totalSize <= sizeLimit else {
                throw ZipExtractError.sizeLimitExceeded(limit: sizeLimit)
            }

            do {
                _ = try archive.extract(entry, to: target)
            } catch {
                throw ZipExtractError.unreadableArchive
            }
        }
    }

    /// Путь записи безопасен, если не пустой, не абсолютный и не содержит `..`.
    /// Делим и по `/`, и по `\`: zip по спецификации использует `/`, но на POSIX
    /// `\` — обычный символ имени, поэтому `..\` без этого проскользнул бы как имя.
    static func isSafeEntryPath(_ path: String) -> Bool {
        if path.isEmpty { return false }
        if path.hasPrefix("/") { return false }
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !components.contains("..")
    }

    /// `url` лежит строго внутри `base` (защита от нормализованных обходов).
    private static func isContained(_ url: URL, in base: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(basePath + "/")
    }
}
