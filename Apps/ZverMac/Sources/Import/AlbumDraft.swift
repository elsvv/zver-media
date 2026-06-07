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

    /// Имя файла обложки в `sourceFolder` (например `folder.jpg`), если найдена
    /// или выбрана. nil — обложки нет. Сам файл не копируется/не правится здесь.
    @Published var artworkFileName: String?

    // MARK: Per-track (правится в превью)

    @Published var tracks: [TrackDraft]

    init(sourceFolder: URL,
         title: String,
         artist: String,
         year: String,
         artworkFileName: String?,
         tracks: [TrackDraft]) {
        self.sourceFolder = sourceFolder
        self.title = title
        self.artist = artist
        self.year = year
        self.artworkFileName = artworkFileName
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
            ($0.trackNumber ?? Int.max, $0.url.lastPathComponent)
                < ($1.trackNumber ?? Int.max, $1.url.lastPathComponent)
        }

        let albumTitle = sortedInfos.first?.album
            ?? folder.lastPathComponent
        let albumArtist = mostCommon(sortedInfos.compactMap(\.artist)) ?? ""
        let albumYear = sortedInfos.compactMap(\.year).first
        let artworkFileURL = sortedInfos.compactMap(\.artworkFileURL).first
        let artworkFileName = artworkFileURL?.lastPathComponent

        let trackDrafts = sortedInfos.map { TrackDraft(info: $0) }

        return AlbumDraft(
            sourceFolder: folder,
            title: albumTitle,
            artist: albumArtist,
            year: albumYear.map(String.init) ?? "",
            artworkFileName: artworkFileName,
            tracks: trackDrafts
        )
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

    /// Имя файла в папке альбома (`fileName` манифеста).
    var fileName: String { fileURL.lastPathComponent }

    /// Расширение файла в нижнем регистре (`fileExtension` манифеста).
    var fileExtension: String { fileURL.pathExtension.lowercased() }

    /// Номер трека как `Int?` (пустая/нечисловая строка → nil).
    var parsedTrackNumber: Int? {
        let trimmed = trackNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    init(info: AudioFileInfo) {
        self.fileURL = info.url
        self.title = info.title
        self.artist = info.artist ?? ""
        self.trackNumber = info.trackNumber.map(String.init) ?? ""
        self.duration = info.duration
        self.sampleRate = info.sampleRate
        self.bitDepth = info.bitDepth
    }
}
