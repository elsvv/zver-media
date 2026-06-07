import Foundation

public enum LibraryScanner {
    private static let audioExtensions: Set<String> = [
        "flac", "m4a", "mp3", "wav", "aiff", "aif", "opus",
    ]

    /// Имена файлов-обложек в порядке убывания приоритета (без учёта регистра).
    private static let artworkNames = ["cover", "folder", "front", "albumart"]
    private static let artworkExtensions: Set<String> = ["jpg", "jpeg", "png"]

    /// Рекурсивно обходит директорию, читает метаданные всех аудиофайлов.
    /// Не-аудио игнорируется, битые аудиофайлы пропускаются.
    /// У файлов без тега ALBUM, лежащих не в корне скана, альбомом становится
    /// имя непосредственной родительской папки.
    /// У файлов без встроенной обложки artworkFileURL указывает на файл
    /// cover/folder/front/albumart (jpg/jpeg/png) из папки трека, если есть.
    /// Результат отсортирован по пути файла.
    ///
    /// Бросает, если корневую директорию невозможно перечислить
    /// (отсутствует/нечитаема): такой сбой — не «пустая библиотека»,
    /// вызывающий код не должен принимать его за реальный результат.
    public static func scan(directory: URL) async throws -> [AudioFileInfo] {
        let urls = try audioURLs(in: directory).sorted { $0.path < $1.path }
        let rootPath = directory.standardizedFileURL.path
        var infos: [AudioFileInfo] = []
        var artworkByFolder: [String: URL?] = [:]
        for url in urls {
            guard var info = try? await MetadataReader.read(url: url) else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            if info.album == nil, parent.path != rootPath {
                info.album = parent.lastPathComponent
            }
            if info.artworkData == nil {
                if let cached = artworkByFolder[parent.path] {
                    info.artworkFileURL = cached
                } else {
                    let found = artworkFileURL(inFolder: parent)
                    artworkByFolder[parent.path] = found
                    info.artworkFileURL = found
                }
            }
            infos.append(info)
        }
        return infos
    }

    private static func artworkFileURL(inFolder folder: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return nil }
        let candidates = files
            .filter { artworkExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for name in artworkNames {
            if let match = candidates.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == name
            }) {
                return match
            }
        }
        return nil
    }

    /// Сбой перечисления корня скана — настоящий throw; недоступная
    /// поддиректория пропускается (её файлы остаются на диске и не должны
    /// валить скан целиком).
    private static func audioURLs(in directory: URL) throws -> [URL] {
        let rootPath = directory.standardizedFileURL.path
        var rootError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            errorHandler: { url, error in
                if url.standardizedFileURL.path == rootPath {
                    rootError = error
                    return false
                }
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown,
                             userInfo: [NSFilePathErrorKey: rootPath])
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            urls.append(url)
        }
        if let rootError { throw rootError }
        return urls
    }
}
