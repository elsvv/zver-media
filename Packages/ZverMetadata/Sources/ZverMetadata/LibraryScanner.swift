import Foundation
import ImageIO

public enum LibraryScanner {
    private static let audioExtensions: Set<String> = [
        "flac", "m4a", "mp3", "wav", "aiff", "aif", "opus",
    ]

    /// Имена файлов-обложек в порядке убывания приоритета (без учёта регистра).
    /// «Передние» имена раньше, чтобы при наличии и front, и back взялась передняя.
    private static let artworkNames = [
        "cover", "folder", "front", "front cover", "albumart",
        "albumartsmall", "album", "art", "artwork",
    ]
    private static let artworkExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]
    private static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    /// Рекурсивно обходит директорию, читает метаданные всех аудиофайлов.
    ///
    /// Диски/стороны: если у альбома есть плейлист (`playlist.m3u8`) в КОРНЕ, он
    /// задаёт деление на диски (метка = папка `CD1`/`Side A`, порядок = из
    /// плейлиста) и перебивает теги. Если плейлиста нет, но треки лежат в
    /// подпапках корня — метка диска = имя подпапки. Иначе — тег `DISCNUMBER`
    /// (метка отсутствует → «Диск N»). Корень альбома — ближайшая папка-предок с
    /// плейлистом или обложкой; так папки-диски `CD1/CD2` остаются ОДНИМ альбомом.
    ///
    /// У файлов без тега ALBUM альбомом становится имя папки-КОРНЯ (не подпапки-
    /// диска), кроме файлов в самом корне скана. Обложка/плейлист/sidecar читаются
    /// из корня альбома. Правки sidecar (ключ — относительный путь внутри альбома)
    /// накладываются поверх всего. Результат отсортирован по пути файла.
    ///
    /// Бросает, если корневую директорию невозможно перечислить.
    public static func scan(directory: URL) async throws -> [AudioFileInfo] {
        let urls = try audioURLs(in: directory).sorted { $0.path < $1.path }
        let scanRoot = directory.standardizedFileURL
        var infos: [AudioFileInfo] = []

        // Кэши: факты о папках (для определения корня) и инфо корня альбома.
        var folderFactsCache: [String: FolderFacts] = [:]
        var rootAlbumCache: [String: RootAlbum] = [:]
        func facts(_ folder: URL) -> FolderFacts {
            if let cached = folderFactsCache[folder.path] { return cached }
            let f = folderFacts(inFolder: folder)
            folderFactsCache[folder.path] = f
            return f
        }
        func rootAlbum(_ root: URL) -> RootAlbum {
            if let cached = rootAlbumCache[root.path] { return cached }
            let a = loadRootAlbum(root: root)
            rootAlbumCache[root.path] = a
            return a
        }

        for url in urls {
            guard var info = try? await MetadataReader.read(url: url) else { continue }
            let parent = url.deletingLastPathComponent().standardizedFileURL
            let root = albumRoot(for: url, scanRoot: scanRoot, facts: facts)
            let album = rootAlbum(root)
            let relPath = relativePath(of: url, under: root)

            // Диск/порядок: плейлист → подпапка → тег DISCNUMBER (уже в info).
            if let disc = album.discMap[relPath.lowercased()] {
                info.discLabel = disc.discLabel
                info.discNumber = disc.discOrdinal
                info.trackNumber = disc.position   // номер внутри диска
            } else if parent.path != root.path, let sub = firstPathComponent(relPath) {
                info.discLabel = sub
                info.discNumber = album.subfolderOrdinal[sub.lowercased()]
                // trackNumber остаётся из тега файла
            }

            // Нет тега альбома → имя папки-КОРНЯ (кроме файлов в корне скана).
            if info.album == nil, root.path != scanRoot.path {
                info.album = root.lastPathComponent
            }

            // Override тегов из sidecar. Ключ — относительный путь внутри альбома
            // (`CD1/01.flac`); фоллбэк на имя файла — для старых плоских sidecar.
            // Любое непустое поле побеждает прочитанное выше (в т.ч. плейлист).
            if let override = album.sidecar?.tracks[relPath]
                ?? album.sidecar?.tracks[url.lastPathComponent] {
                if let t = override.title { info.title = t }
                if let a = override.artist { info.artist = a }
                if let al = override.album { info.album = al }
                if let y = override.year { info.year = y }
                if let n = override.trackNumber { info.trackNumber = n }
                if let d = override.discNumber { info.discNumber = d }
                if let dl = override.discLabel { info.discLabel = dl }
            }

            // Обложка: sidecar.artworkFileName (относительно корня) побеждает
            // встроенную; иначе, при отсутствии встроенной, — обложка из корня.
            if let artworkFileName = album.sidecar?.artworkFileName {
                info.artworkFileURL = root.appendingPathComponent(artworkFileName)
            } else if info.artworkData == nil {
                info.artworkFileURL = album.coverURL
            }

            infos.append(info)
        }
        return infos
    }

    // MARK: - Корень альбома и его инфо

    /// Факты о папке для определения корня альбома.
    private struct FolderFacts {
        let hasPlaylist: Bool
        let hasCover: Bool
    }

    /// Инфо корня альбома: карта дисков из плейлиста (по относительным путям),
    /// sidecar, обложка и порядок подпапок-дисков (фоллбэк без плейлиста).
    private struct RootAlbum {
        let discMap: [String: M3UPlaylist.DiscInfo]
        let sidecar: AlbumSidecar?
        let coverURL: URL?
        let subfolderOrdinal: [String: Int]
    }

    /// Корень альбома для файла: ближайший предок (от родителя вверх, не включая
    /// корень скана) с плейлистом; иначе — ближайший с обложкой; иначе — родитель.
    /// Плейлист — сильнейший сигнал (лежит в корне альбома, не в папке-диске).
    private static func albumRoot(for url: URL, scanRoot: URL,
                                  facts: (URL) -> FolderFacts) -> URL {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        var ancestors: [URL] = []
        var cur = parent
        while cur.path != scanRoot.path && cur.path.hasPrefix(scanRoot.path + "/") {
            ancestors.append(cur)
            let up = cur.deletingLastPathComponent().standardizedFileURL
            if up.path == cur.path { break }
            cur = up
        }
        if let byPlaylist = ancestors.first(where: { facts($0).hasPlaylist }) {
            return byPlaylist
        }
        if let byCover = ancestors.first(where: { facts($0).hasCover }) {
            return byCover
        }
        return parent
    }

    private static func folderFacts(inFolder folder: URL) -> FolderFacts {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return FolderFacts(hasPlaylist: false, hasCover: false) }
        let hasPlaylist = files.contains { playlistExtensions.contains($0.pathExtension.lowercased()) }
        let hasCover = files.contains { artworkExtensions.contains($0.pathExtension.lowercased()) }
        return FolderFacts(hasPlaylist: hasPlaylist, hasCover: hasCover)
    }

    private static func loadRootAlbum(root: URL) -> RootAlbum {
        let sidecar = loadSidecar(inFolder: root)
        let coverURL = artworkFileURL(inFolder: root)

        var discMap: [String: M3UPlaylist.DiscInfo] = [:]
        if let url = playlistURL(inFolder: root), let content = readText(url) {
            discMap = M3UPlaylist.discMap(from: content)
        }

        // Порядок подпапок-дисков (фоллбэк без плейлиста): непосредственные
        // подпапки корня, натурально отсортированные → 1-based.
        var subfolderOrdinal: [String: Int] = [:]
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            let subdirs = entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for (index, name) in subdirs.enumerated() {
                subfolderOrdinal[name.lowercased()] = index + 1
            }
        }

        return RootAlbum(discMap: discMap, sidecar: sidecar,
                         coverURL: coverURL, subfolderOrdinal: subfolderOrdinal)
    }

    /// Плейлист (`.m3u`/`.m3u8`) в папке; при нескольких — первый по имени.
    private static func playlistURL(inFolder folder: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return nil }
        return files
            .filter { playlistExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }

    /// Путь `url` относительно корня альбома (`CD1/01.flac`); вне корня — имя файла.
    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    /// Первый сегмент относительного пути (папка-диск), если путь вложенный.
    private static func firstPathComponent(_ relPath: String) -> String? {
        let parts = relPath.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 2 ? parts.first.map(String.init) : nil
    }

    // MARK: - Sidecar / текст / обложка

    /// Читает sidecar из папки. Отсутствие/битый/нечитаемый файл → `nil`.
    private static func loadSidecar(inFolder folder: URL) -> AlbumSidecar? {
        let url = folder.appendingPathComponent(AlbumSidecar.fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AlbumSidecar.self, from: data)
    }

    /// Текст файла в наиболее вероятной кодировке: UTF-8 (`.m3u8` по стандарту,
    /// большинство `.m3u`), затем системная определялка, затем Latin-1 (старые `.m3u`).
    private static func readText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var used = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &used) { return s }
        return try? String(contentsOf: url, encoding: .isoLatin1)
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
        // Узнаваемых имён нет — берём самую крупную картинку (передняя обложка
        // почти всегда крупнее back/booklet/disc-иконок). При полном отсутствии
        // картинок — nil.
        return largestImage(among: candidates)
    }

    /// Самая крупная картинка по разрешению (ширина×высота через ImageIO без
    /// полного декода); тай-брейк — размер файла. `urls` отсортированы по имени
    /// по возрастанию, поэтому при равном счёте остаётся алфавитно первая
    /// (детерминизм). Нечитаемые как изображение получают счёт (0, …).
    private static func largestImage(among urls: [URL]) -> URL? {
        var best: URL?
        var bestScore = (-1, -1)
        for url in urls {
            let score = (pixelCount(url) ?? 0, fileSize(url))
            if score.0 > bestScore.0
                || (score.0 == bestScore.0 && score.1 > bestScore.1) {
                best = url
                bestScore = score
            }
        }
        return best
    }

    private static func pixelCount(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return width * height
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
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
