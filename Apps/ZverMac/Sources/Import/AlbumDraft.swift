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

    /// Пути (относительно `sourceFolder`) файлов-компаньонов релиза — `.cue`/`.log`.
    /// `.cue` несёт авторитетные границы cue-треков (телефон раскроет образ при
    /// рескане), `.log` — целостность рипа. Едут на телефон как есть, не правятся.
    let extraFileNames: [String]

    // MARK: Per-track (правится в превью)

    @Published var tracks: [TrackDraft]

    /// Целевое качество конвертации DSD → FLAC (только для DSD-альбомов; выбирается
    /// в превью). У обычных альбомов игнорируется.
    @Published var dsdQuality: DSDQuality = .default

    /// Прогресс конвертации DSD во время постановки в очередь (готово/всего), либо
    /// nil, если конвертация не идёт. Показывается в футере превью.
    @Published private(set) var conversionProgress: ConversionProgress?

    /// Поколение конвертации: `endConversion` его двигает, поэтому «поздние»
    /// фоновые прогресс-хопы (запланированные до завершения, но выполнившиеся после
    /// сброса) со старым поколением игнорируются и не воскрешают «N/N» после конца.
    private var conversionGeneration = 0

    /// Начинает конвертацию: сбрасывает прогресс в 0/total и возвращает поколение.
    func beginConversion(total: Int) -> Int {
        conversionGeneration += 1
        conversionProgress = ConversionProgress(done: 0, total: total)
        return conversionGeneration
    }

    /// Обновляет прогресс, только если поколение актуально (иначе — поздний хоп).
    func reportConversion(done: Int, total: Int, generation: Int) {
        guard generation == conversionGeneration else { return }
        conversionProgress = ConversionProgress(done: done, total: total)
    }

    /// Завершает конвертацию: двигает поколение (гасит поздние хопы) и чистит прогресс.
    func endConversion() {
        conversionGeneration += 1
        conversionProgress = nil
    }

    /// Есть ли в альбоме DSD-треки (`.dsf`) — тогда показываем пикер качества.
    var hasDSD: Bool { tracks.contains { $0.isDSD } }

    init(sourceFolder: URL,
         title: String,
         artist: String,
         year: String,
         artworkFileName: String?,
         playlistFileName: String? = nil,
         extraFileNames: [String] = [],
         tracks: [TrackDraft]) {
        self.sourceFolder = sourceFolder
        self.title = title
        self.artist = artist
        self.year = year
        self.artworkFileName = artworkFileName
        self.playlistFileName = playlistFileName
        self.extraFileNames = extraFileNames
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
        let extraFileNames = extraFileNames(under: folder)

        let trackDrafts = sortedInfos.map { TrackDraft(info: $0, albumRoot: folder) }

        return AlbumDraft(
            sourceFolder: folder,
            title: albumTitle,
            artist: albumArtist,
            year: albumYear.map(String.init) ?? "",
            artworkFileName: artworkFileName,
            playlistFileName: playlistFileName,
            extraFileNames: extraFileNames,
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

    private static let extraExtensions: Set<String> = ["cue", "log"]

    /// Файлы-компаньоны релиза (`.cue`/`.log`) под корнем альбома, РЕКУРСИВНО, с
    /// путями относительно корня (`Album.cue`, `CD1/Album.cue`) — как треки. Так
    /// `.cue` приедет на телефон одноимённым братом контейнера (в той же подпапке),
    /// и сканер раскроет образ. Отсортированы по имени (детерминизм). Едут как есть.
    private static func extraFileNames(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var names: [String] = []
        for case let url as URL in enumerator {
            guard extraExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            names.append(relativePath(of: url, under: root))
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Наиболее частое значение (мода) для вывода album-артиста из тегов треков.
    private static func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }
}

/// Прогресс конвертации DSD → FLAC при постановке альбома в очередь.
struct ConversionProgress: Equatable {
    var done: Int
    var total: Int
}

/// Редактируемый трек внутри `AlbumDraft`.
///
/// Правятся `title`/`artist`/`trackNumber`; технические поля (длительность,
/// частота, разрядность, размер, расширение) берутся из скана и не редактируются.
/// `fileURL` — исходный файл, который будет раздан как есть.
struct TrackDraft: Identifiable, Sendable {
    /// Стабильный id для `ForEach`. У обычного трека — путь исходного файла; у
    /// cue-образа N логических треков делят ОДИН контейнер `.flac`, поэтому в id
    /// входит `cueIndex` — иначе одинаковый id даёт коллизию в `ForEach` (SwiftUI
    /// рендерит первую строку для всех: одинаковые название/номер во всех треках).
    var id: String {
        cueIndex.map { "\(fileURL.path)#\($0)" } ?? fileURL.path
    }

    let fileURL: URL
    /// Номер cue-трека (1-based) внутри контейнера (image+cue); nil у обычных треков.
    /// Различает логические треки, делящие один физический `.flac`.
    let cueIndex: Int?
    /// Источник — DSD (`.dsf`): при постановке в очередь Мак сконвертит его в FLAC.
    /// `sampleRate` тут — частота DSD (для метки «DSD64» в превью).
    let isDSD: Bool

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
        self.cueIndex = info.cueIndex
        self.isDSD = info.isDSD
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
