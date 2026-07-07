import Foundation
import ZverMetadata
import ZverTransport

/// Итог импорта одного альбома. Достаточно, чтобы показать баннер «Импортирован
/// <артист — альбом>» и (при желании вызывающего) сходить в папку.
public struct ImportResult: Sendable, Equatable {
    /// Папка альбома в библиотеке (`Documents/Library/<folderName>`).
    public let albumFolder: URL
    /// Артист альбома (из тегов); nil у безымянных рипов.
    public let artist: String?
    /// Название альбома: тег ALBUM или фоллбэк (папка/имя zip/родительская папка).
    public let album: String
    /// Число аудиодорожек альбома (всех, а не только доложенных при повторе).
    public let trackCount: Int

    public init(albumFolder: URL, artist: String?, album: String, trackCount: Int) {
        self.albumFolder = albumFolder
        self.artist = artist
        self.album = album
        self.trackCount = trackCount
    }
}

/// Раскладывает музыку из внешних источников в `Documents/Library`.
///
/// Ядро фичи импорта: и zip-архив (Bandcamp), и россыпь файлов (Internet Archive,
/// document picker) приходят сюда. Треки группируются по тегам `(artist, album)`
/// через `MetadataReader`; нет тега ALBUM — фоллбэк на имя корневой папки архива /
/// имя zip (у Bandcamp это `Artist - Album`) / родительскую папку файла. Папка
/// альбома — детерминированная `AlbumIdentity.folderName(...)`. Повтор идемпотентен:
/// папка есть — докладываем недостающие файлы, существующие не трогаем. Источник
/// (zip/staging-копии) удаляется после успеха.
///
/// Рескан библиотеки НЕ дёргается — это делает вызывающий (`rescan`-замыкание
/// вкладки «Импорт»).
public struct AlbumImporter: Sendable {
    /// Корень библиотеки — `Documents/Library`.
    private let libraryRoot: URL
    /// База для распаковки архивов. По умолчанию — системный tmp (тот же том, что и
    /// библиотека в песочнице iOS → move дешёвый). Инъекция для тестов чистки staging.
    private let stagingBase: URL

    public init(libraryRoot: URL) {
        self.init(libraryRoot: libraryRoot,
                  stagingBase: FileManager.default.temporaryDirectory)
    }

    init(libraryRoot: URL, stagingBase: URL) {
        self.libraryRoot = libraryRoot
        self.stagingBase = stagingBase
    }

    /// Аудио-расширения — как в `LibraryScanner` (тот держит список приватным).
    /// Синхронизировать при добавлении форматов.
    static let audioExtensions: Set<String> = [
        "flac", "m4a", "mp3", "wav", "aiff", "aif", "opus", "dsf",
    ]

    private var fileManager: FileManager { .default }

    // MARK: - Публичный API

    /// Импортирует альбом(ы) из zip-архива. Распаковывает его в staging (тот же том),
    /// группирует треки по тегам, раскладывает по папкам библиотеки с сохранением
    /// поддиректорий (multi-disc). По успеху удаляет и staging, и сам zip.
    @discardableResult
    public func importArchive(_ zipURL: URL) async throws -> [ImportResult] {
        let staging = try ZipExtractor.extract(zipURL, into: stagingBase)
        // staging чистим всегда — треки уже переехали в библиотеку, распакованное сырьё
        // не нужно; на ошибке — тем более (частичная раскладка идемпотентно до-льётся).
        defer { try? fileManager.removeItem(at: staging) }

        let (audio, sidecars) = classify(enumerateFiles(in: staging))
        let fallback = archiveFallbackName(staging: staging, zipURL: zipURL)
        let groups = try await buildGroups(
            audio: audio, sidecars: sidecars,
            fallbackName: { _ in fallback },
            layout: .preserveSubdirectories
        )
        let results = try execute(groups)
        // Источник удаляем только по успеху раскладки (иначе повтор невозможен).
        try? fileManager.removeItem(at: zipURL)
        return results
    }

    /// Импортирует россыпь файлов (Internet Archive, document picker). Группирует так
    /// же по тегам, но кладёт плоско (`<folderName>/<имя файла>` без поддиректорий —
    /// у россыпи нет дерева архива). Источники (staging-копии) удаляются после успеха.
    @discardableResult
    public func importFiles(_ urls: [URL]) async throws -> [ImportResult] {
        let (audio, sidecars) = classify(urls)
        let groups = try await buildGroups(
            audio: audio, sidecars: sidecars,
            fallbackName: { $0.deletingLastPathComponent().lastPathComponent },
            layout: .flat
        )
        let results = try execute(groups)
        // Всё переданное — staging-копии вызывающего; подчищаем и то, что не переехало
        // (пропущенные дубли, неприкреплённые sidecar'ы).
        for url in urls { try? fileManager.removeItem(at: url) }
        return results
    }

    /// Импортирует смешанный набор выбранных файлов (`fileImporter` источника «Из
    /// файлов»): zip-архивы уходят каждый в `importArchive` (свой альбом(ы)), всё
    /// остальное — одним пакетом в `importFiles` (россыпь группируется по тегам).
    /// Результаты объединяются: сперва альбомы из архивов (в порядке `urls`), затем из
    /// россыпи. Источники удаляются после успеха своими методами; на ошибке любого шага
    /// исключение пробрасывается наверх (уже разложенные альбомы остаются, повтор
    /// идемпотентен).
    @discardableResult
    public func importPicked(_ urls: [URL]) async throws -> [ImportResult] {
        var results: [ImportResult] = []
        var loose: [URL] = []
        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                results += try await importArchive(url)
            } else {
                loose.append(url)
            }
        }
        if !loose.isEmpty {
            results += try await importFiles(loose)
        }
        return results
    }

    // MARK: - Группировка

    /// Способ раскладки файлов группы в папке альбома.
    private enum Layout {
        /// Сохранять поддиректории относительно общего корня группы (архивы).
        case preserveSubdirectories
        /// Плоско, по имени файла (россыпь).
        case flat
    }

    /// Копилка одной группы `(artist, album)` в процессе планирования. Reference-тип —
    /// удобно дополнять; за пределы `await` не выносится (все чтения тегов уже позади).
    private final class Group {
        let artist: String?
        let album: String
        var year: Int?
        var audio: [URL] = []
        /// Общий корень аудио группы (для `preserveSubdirectories`); nil при `flat`.
        var base: URL?
        /// (источник → относительный путь назначения внутри папки альбома).
        var files: [(source: URL, relPath: String)] = []

        init(artist: String?, album: String, year: Int?) {
            self.artist = artist
            self.album = album
            self.year = year
        }
    }

    private func buildGroups(
        audio: [URL],
        sidecars: [URL],
        fallbackName: (URL) -> String,
        layout: Layout
    ) async throws -> [Group] {
        // Сначала читаем ВСЕ теги (единственные await), потом синхронно группируем —
        // Group (не-Sendable) не пересекает границу await.
        var infos: [(url: URL, info: AudioFileInfo)] = []
        for url in audio.sorted(by: { $0.path < $1.path }) {
            guard let info = try? await MetadataReader.read(url: url) else { continue }
            infos.append((url, info))
        }

        var order: [String] = []
        var byKey: [String: Group] = [:]
        for (url, info) in infos {
            let artist = normalized(info.artist)
            let album = normalized(info.album) ?? fallbackName(url)
            let key = (artist ?? "") + "\u{0}" + album
            let group: Group
            if let existing = byKey[key] {
                group = existing
            } else {
                group = Group(artist: artist, album: album, year: info.year)
                byKey[key] = group
                order.append(key)
            }
            if group.year == nil { group.year = info.year }   // первый непустой год
            group.audio.append(url)
        }
        let groups = order.map { byKey[$0]! }

        // Базовый корень + плановые пути аудио.
        for group in groups {
            switch layout {
            case .preserveSubdirectories: group.base = commonAncestor(of: group.audio)
            case .flat:                   group.base = nil
            }
            group.files = group.audio.map { ($0, relativePath(of: $0, base: group.base)) }
        }

        // Sidecar'ы (обложки/cue/плейлисты) — к подходящей группе.
        for sidecar in sidecars {
            if let group = assign(sidecar: sidecar, to: groups, layout: layout) {
                group.files.append((sidecar, relativePath(of: sidecar, base: group.base)))
            }
        }
        return groups
    }

    /// К какой группе отнести sidecar.
    ///
    /// - `preserveSubdirectories`: к группе, чей `base` содержит файл (при вложенности —
    ///   к самой глубокой); если ни один не содержит, но альбом один — к нему (обложка
    ///   в корне архива над треками-в-подпапке всё равно нужна).
    /// - `flat`: один альбом — к нему; иначе — к группе с треком из той же папки.
    private func assign(sidecar: URL, to groups: [Group], layout: Layout) -> Group? {
        switch layout {
        case .preserveSubdirectories:
            let containing = groups.filter { group in
                guard let base = group.base else { return false }
                return isDescendant(sidecar, of: base)
            }
            if let deepest = containing.max(by: {
                ($0.base?.pathComponents.count ?? 0) < ($1.base?.pathComponents.count ?? 0)
            }) {
                return deepest
            }
            return groups.count == 1 ? groups.first : nil
        case .flat:
            if groups.count == 1 { return groups.first }
            let parent = sidecar.deletingLastPathComponent().standardizedFileURL.path
            return groups.first { group in
                group.audio.contains {
                    $0.deletingLastPathComponent().standardizedFileURL.path == parent
                }
            }
        }
    }

    // MARK: - Раскладка

    /// Переносит файлы всех групп в папки библиотеки. Идемпотентно: существующий файл
    /// назначения не трогаем, источник-дубль убираем. Возвращает по `ImportResult` на
    /// группу.
    private func execute(_ groups: [Group]) throws -> [ImportResult] {
        var results: [ImportResult] = []
        for group in groups {
            let folderName = AlbumIdentity.folderName(
                artist: group.artist, title: group.album, year: group.year)
            let albumFolder = libraryRoot.appendingPathComponent(folderName, isDirectory: true)

            for (source, relPath) in group.files {
                let dest = albumFolder.appendingPathComponent(relPath)
                if fileManager.fileExists(atPath: dest.path) {
                    // Уже на месте — существующее не трогаем, лишний источник убираем.
                    try? fileManager.removeItem(at: source)
                    continue
                }
                try fileManager.createDirectory(
                    at: dest.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try fileManager.moveItem(at: source, to: dest)
            }

            results.append(ImportResult(
                albumFolder: albumFolder, artist: group.artist,
                album: group.album, trackCount: group.audio.count))
        }
        return results
    }

    // MARK: - Классификация и имена

    /// Делит URL'ы на аудио и sidecar'ы (обложки/cue/плейлисты); всё вне белого списка
    /// `ZipExtractor.allowedExtensions` игнорирует.
    private func classify(_ urls: [URL]) -> (audio: [URL], sidecars: [URL]) {
        var audio: [URL] = []
        var sidecars: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if Self.audioExtensions.contains(ext) {
                audio.append(url)
            } else if ZipExtractor.allowedExtensions.contains(ext) {
                sidecars.append(url)
            }
        }
        return (audio, sidecars)
    }

    /// Все обычные файлы в дереве (рекурсивно). Недоступную папку молча пропускаем.
    private func enumerateFiles(in dir: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                urls.append(url)
            }
        }
        return urls
    }

    /// Фоллбэк-имя альбома для архива: единственная папка верхнего уровня (обёртка
    /// `Artist - Album/`) — её имя; иначе (файлы в корне архива) — имя zip без
    /// расширения (у Bandcamp тоже `Artist - Album`).
    private func archiveFallbackName(staging: URL, zipURL: URL) -> String {
        let entries = (try? fileManager.contentsOfDirectory(
            at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let files = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
        }
        if dirs.count == 1, files.isEmpty {
            return dirs[0].lastPathComponent
        }
        return zipURL.deletingPathExtension().lastPathComponent
    }

    /// Тег → nil, если пустой/из пробелов; иначе триммнутое значение.
    private func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Пути

    /// Глубочайшая общая папка-предок набора файлов. Для одного файла — его папка.
    private func commonAncestor(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var prefix = first.deletingLastPathComponent().standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let comps = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            var i = 0
            while i < prefix.count, i < comps.count, prefix[i] == comps[i] { i += 1 }
            prefix = Array(prefix.prefix(i))
        }
        var result = URL(fileURLWithPath: "/")
        for comp in prefix.dropFirst() {   // dropFirst — ведущий "/"
            result.appendPathComponent(comp)
        }
        return result.standardizedFileURL
    }

    /// Путь `url` относительно `base` (`CD1/01.flac`); при nil-базе (flat) или вне
    /// базы — просто имя файла.
    private func relativePath(of url: URL, base: URL?) -> String {
        guard let base else { return url.lastPathComponent }
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") {
            return String(path.dropFirst(basePath.count + 1))
        }
        return url.lastPathComponent
    }

    /// `url` лежит строго внутри `base`.
    private func isDescendant(_ url: URL, of base: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(basePath + "/")
    }
}
