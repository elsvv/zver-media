import Foundation
import ZverMetadata
import ZverTransport

/// Редактируемая модель альбома на Маке перед отправкой на iPhone.
///
/// Превью + инлайн-редактор работают ИСКЛЮЧИТЕЛЬНО с этой моделью в памяти:
/// исходные аудиофайлы НЕ перезаписываются. Правки (album-уровень и per-track)
/// уйдут в манифест (`ManifestBuilder`), телефон материализует их в sidecar
/// `album.zvermeta.json` при импорте. Источник правды о метадате на устройстве —
/// файловая система телефона, а не файлы на Маке.
///
/// `@MainActor`: модель редактируется из UI (`AlbumPreviewView`).
@MainActor
final class AlbumDraft: ObservableObject, Identifiable {
    /// Стабильный идентификатор черновика в рамках сессии приложения
    /// (нужен спискам/`ForEach`; не путать с `albumId` протокола).
    let id = UUID()

    /// Папка, из которой импортирован альбом (источник файлов для раздачи).
    let sourceFolder: URL

    // MARK: Album-уровень (правится в превью)

    @Published var title: String
    @Published var artist: String
    @Published var year: String

    /// Имя файла обложки ОТНОСИТЕЛЬНО `sourceFolder` (например `cover.jpg`), если
    /// найдена или выбрана. nil — обложки нет. Сам файл не копируется/не правится.
    @Published var artworkFileName: String?

    /// Имя файла плейлиста в корне альбома (`playlist.m3u8`/`.m3u`), если есть. Едет
    /// на телефон как файл-компаньон и задаёт деление на диски. nil — плейлиста нет.
    @Published var playlistFileName: String?

    // MARK: Per-track (правится в превью)

    @Published var tracks: [TrackDraft]

    init(sourceFolder: URL,
         title: String,
         artist: String,
         year: String,
         artworkFileName: String?,
         playlistFileName: String? = nil,
         tracks: [TrackDraft]) {
        self.sourceFolder = sourceFolder
        self.title = title
        self.artist = artist
        self.year = year
        self.artworkFileName = artworkFileName
        self.playlistFileName = playlistFileName
        self.tracks = tracks
    }

    /// `albumId` протокола синка (детерминированный, общий для Мака и iPhone).
    /// Перезаливка обновляет альбом на месте, без дублей.
    var albumId: String {
        AlbumIdentity.folderName(
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            year: parsedYear
        )
    }

    /// Год как `Int?` (пустая/нечисловая строка → nil).
    var parsedYear: Int? {
        let trimmed = year.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    /// Полный URL файла обложки в исходной папке, если имя задано.
    var artworkURL: URL? {
        artworkFileName.map { sourceFolder.appendingPathComponent($0) }
    }

    /// Собирает черновик из результата скана папки (`LibraryScanner.scan`).
    ///
    /// Album-уровень выводится из первого трека (или мажоритарных значений) —
    /// пользователь правит в превью. Обложка берётся из `artworkFileURL` любого
    /// трека (сканер уже нашёл `folder.jpg`/sidecar). Файлы не читаются повторно.
    static func from(folder: URL, infos: [AudioFileInfo]) -> AlbumDraft {
        let sortedInfos = infos.sorted {
            ($0.discNumber ?? 1, $0.trackNumber ?? Int.max, $0.url.lastPathComponent)
                < ($1.discNumber ?? 1, $1.trackNumber ?? Int.max, $1.url.lastPathComponent)
        }

        let albumTitle = sortedInfos.first?.album
            ?? folder.lastPathComponent
        let albumArtist = mostCommon(sortedInfos.compactMap(\.artist)) ?? ""
        let albumYear = sortedInfos.compactMap(\.year).first

        // Обложку и плейлист берём из КОРНЯ альбома (дропнутой папки), а не из
        // подпапок-дисков: у много-дискового рипа cover.jpg/playlist.m3u8 лежат
        // сверху. Фоллбэк обложки — на найденную сканером у трека (плоский альбом).
        let rootCover = coverFileName(inRoot: folder)
        let artworkFileName = rootCover
            ?? sortedInfos.compactMap(\.artworkFileURL).first.map {
                relativePath(of: $0, under: folder)
            }
        let playlistFileName = playlistFileName(inRoot: folder)

        let trackDrafts = sortedInfos.map { TrackDraft(info: $0, albumRoot: folder) }

        return AlbumDraft(
            sourceFolder: folder,
            title: albumTitle,
            artist: albumArtist,
            year: albumYear.map(String.init) ?? "",
            artworkFileName: artworkFileName,
            playlistFileName: playlistFileName,
            tracks: trackDrafts
        )
    }

    /// Путь `url` относительно корня альбома (`CD1/01 - x.flac`); если файл не под
    /// корнем — просто его имя. `nonisolated`: чистая функция, зовётся из
    /// `TrackDraft.init` (не на MainActor).
    nonisolated static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private static let coverNames = ["cover", "folder", "front", "front cover", "albumart"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// Обложка в корне альбома: файл `cover/folder/front…` (jpg/png/webp) в верхнем
    /// уровне папки. Имя (относительно корня) или nil.
    private static func coverFileName(inRoot root: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        for name in coverNames {
            if let match = images.first(where: {
                $0.deletingPathExtension().lastPathComponent.lowercased() == name
            }) {
                return match.lastPathComponent
            }
        }
        return images.first?.lastPathComponent
    }

    /// Плейлист (`.m3u8`/`.m3u`) в корне альбома. Имя или nil. При нескольких —
    /// первый по имени (детерминизм).
    private static func playlistFileName(inRoot root: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        return files
            .filter { ["m3u", "m3u8"].contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
    }

    /// Наиболее частое значение (мода) для вывода album-артиста из тегов треков.
    private static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Редактируемый трек внутри `AlbumDraft`.
///
/// Правятся `title`/`artist`/`trackNumber`; технические поля (длительность,
/// частота, разрядность, размер, расширение) берутся из скана и не редактируются.
/// `fileURL` — исходный файл, который будет раздан как есть.
struct TrackDraft: Identifiable, Sendable {
    /// Стабильный id для `ForEach` — путь исходного файла.
    var id: String { fileURL.path }

    let fileURL: URL

    // Правятся в превью.
    var title: String
    var artist: String
    var trackNumber: String

    // Технические (read-only, из скана).
    let duration: Double
    let sampleRate: Double
    let bitDepth: Int?
    /// Номер диска из тега (read-only): проносится в манифест/sidecar как есть,
    /// чтобы телефон делил альбом на «Диск N». Пока не правится в превью.
    let discNumber: Int?
    /// Путь файла ОТНОСИТЕЛЬНО корня альбома (`CD1/01 - x.flac` для дисков-подпапок,
    /// иначе просто имя файла). Именно он едет в манифест как `fileName`, чтобы
    /// телефон воссоздал структуру папок один-в-один.
    let relativePath: String

    /// Имя файла в папке альбома (последний компонент — для отображения).
    var fileName: String { fileURL.lastPathComponent }

    /// Расширение файла в нижнем регистре (`fileExtension` манифеста).
    var fileExtension: String { fileURL.pathExtension.lowercased() }

    /// Номер трека как `Int?` (пустая/нечисловая строка → nil).
    var parsedTrackNumber: Int? {
        let trimmed = trackNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    init(info: AudioFileInfo, albumRoot: URL) {
        self.fileURL = info.url
        self.title = info.title
        self.artist = info.artist ?? ""
        self.trackNumber = info.trackNumber.map(String.init) ?? ""
        self.duration = info.duration
        self.sampleRate = info.sampleRate
        self.bitDepth = info.bitDepth
        self.discNumber = info.discNumber
        self.relativePath = AlbumDraft.relativePath(of: info.url, under: albumRoot)
    }
}
