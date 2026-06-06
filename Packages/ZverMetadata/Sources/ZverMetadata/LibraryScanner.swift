import Foundation

public enum LibraryScanner {
    private static let audioExtensions: Set<String> = [
        "flac", "m4a", "mp3", "wav", "aiff", "aif", "opus",
    ]

    /// Рекурсивно обходит директорию, читает метаданные всех аудиофайлов.
    /// Не-аудио игнорируется, битые аудиофайлы пропускаются.
    /// Результат отсортирован по пути файла.
    public static func scan(directory: URL) async throws -> [AudioFileInfo] {
        let urls = audioURLs(in: directory).sorted { $0.path < $1.path }
        var infos: [AudioFileInfo] = []
        for url in urls {
            guard let info = try? await MetadataReader.read(url: url) else { continue }
            infos.append(info)
        }
        return infos
    }

    private static func audioURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            urls.append(url)
        }
        return urls
    }
}
