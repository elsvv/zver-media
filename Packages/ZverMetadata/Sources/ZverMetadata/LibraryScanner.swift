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
    /// Если в папке есть валидный sidecar (`album.zvermeta.json`), его правки
    /// тегов накладываются поверх прочитанных (override побеждает тег), а
    /// `artworkFileName` из sidecar выставляет artworkFileURL независимо от
    /// встроенной обложки. Битый/нечитаемый sidecar игнорируется.
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
        var sidecarByFolder: [String: AlbumSidecar?] = [:]
        for url in urls {
            guard var info = try? await MetadataReader.read(url: url) else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL

            // Sidecar читаем один раз на папку (как и обложку).
            let sidecar: AlbumSidecar?
            if let cached = sidecarByFolder[parent.path] {
                sidecar = cached
            } else {
                let loaded = loadSidecar(inFolder: parent)
                sidecarByFolder[parent.path] = loaded
                sidecar = loaded
            }

            // Override тегов: любое непустое поле побеждает прочитанный тег.
            if let override = sidecar?.tracks[url.lastPathComponent] {
                if let t = override.title { info.title = t }
                if let a = override.artist { info.artist = a }
                if let al = override.album { info.album = al }
                if let y = override.year { info.year = y }
                if let n = override.trackNumber { info.trackNumber = n }
            }

            if info.album == nil, parent.path != rootPath {
                info.album = parent.lastPathComponent
            }

            // artworkFileName из sidecar побеждает встроенную обложку: сканер
            // выставляет artworkFileURL даже при наличии встроенной обложки
            // (artworkData != nil), отдавая показу оба источника.
            // TODO(S3-11): приоритет ПОКАЗА над embedded — за стороной iOS.
            // Сейчас ArtworkLoader.load (Apps/ZverIOS/Sources/Player/) сначала
            // отдаёт встроенную artworkData и только при её отсутствии падает на
            // artworkFileURL — поэтому для трека со встроенной обложкой правленая
            // на Маке обложка из sidecar на экран НЕ попадёт. Закрыть в S3-11:
            // либо при наличии sidecar-обложки предпочитать artworkFileURL
            // встроенной, либо телефон при импорте материализует override как
            // файл и не оставляет встроенную видимой. Контракт сканера (этот
            // overlay) от решения показа не зависит и покрыт тестами.
            if let artworkFileName = sidecar?.artworkFileName {
                info.artworkFileURL = parent.appendingPathComponent(artworkFileName)
            } else if info.artworkData == nil {
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

    /// Читает sidecar из папки. Отсутствие/битый/нечитаемый файл → `nil`
    /// (фоллбэк к тегам), скан не падает.
    private static func loadSidecar(inFolder folder: URL) -> AlbumSidecar? {
        let url = folder.appendingPathComponent(AlbumSidecar.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AlbumSidecar.self, from: data)
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
