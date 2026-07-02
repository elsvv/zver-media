import Foundation

/// Альбом в манифесте. `id` — детерминированный санитизированный
/// `<artist> - <title> (<year>)` (см. `AlbumIdentity`): перезаливка обновляет
/// альбом на месте, без дублей.
public struct ManifestAlbum: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var year: Int?
    public var artwork: ManifestArtwork?
    /// Плейлист-компаньон в корне альбома (`playlist.m3u8`), задающий деление на
    /// диски/стороны и порядок. Опционален: у одно-дисковых альбомов его нет.
    /// Старые манифесты без ключа декодируются в nil.
    public var playlist: ManifestFile?
    /// Файлы-компаньоны релиза сверх обложки/плейлиста: `.cue` (авторитетные
    /// границы cue-треков) и `.log` (отчёт рипа EAC/XLD). Как `artwork`/`playlist` —
    /// `{fileName, sha, size}`. У cue-образа N `tracks` делят один `fileName`
    /// контейнера, а `.cue` едет здесь: телефон при рескане раскрывает образ по
    /// авторитетным офсетам из `.cue` (в манифест офсеты не кладём — нет дрейфа).
    /// Старые манифесты без ключа декодируются в пустой массив.
    public var extras: [ManifestFile]
    public var tracks: [ManifestTrack]

    public init(id: String,
                title: String,
                artist: String? = nil,
                year: Int? = nil,
                artwork: ManifestArtwork? = nil,
                playlist: ManifestFile? = nil,
                extras: [ManifestFile] = [],
                tracks: [ManifestTrack]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.artwork = artwork
        self.playlist = playlist
        self.extras = extras
        self.tracks = tracks
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, year, artwork, playlist, extras, tracks
    }

    /// Обратная совместимость: манифесты, собранные до `extras`, не содержат ключа —
    /// декодер даёт пустой массив, а не падает (как `playlist`/`artwork` → nil).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        artwork = try c.decodeIfPresent(ManifestArtwork.self, forKey: .artwork)
        playlist = try c.decodeIfPresent(ManifestFile.self, forKey: .playlist)
        extras = try c.decodeIfPresent([ManifestFile].self, forKey: .extras) ?? []
        tracks = try c.decode([ManifestTrack].self, forKey: .tracks)
    }
}

/// Трек альбома. Метадата — это уже правленые на Маке значения; исходные файлы
/// не перезаписываются, телефон материализует правки в sidecar при импорте.
public struct ManifestTrack: Codable, Equatable, Sendable {
    public var fileName: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    /// Номер диска (1-based) для много-дисковых альбомов. Опционально:
    /// старые манифесты без ключа декодируются в nil (одно-дисковый).
    public var discNumber: Int?
    public var year: Int?
    public var duration: Double
    public var sampleRate: Int
    public var bitDepth: Int?
    public var fileSize: Int
    public var sha256: String
    public var fileExtension: String

    public init(fileName: String,
                title: String,
                artist: String? = nil,
                album: String? = nil,
                trackNumber: Int? = nil,
                discNumber: Int? = nil,
                year: Int? = nil,
                duration: Double,
                sampleRate: Int,
                bitDepth: Int? = nil,
                fileSize: Int,
                sha256: String,
                fileExtension: String) {
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileSize = fileSize
        self.sha256 = sha256
        self.fileExtension = fileExtension
    }
}

/// Раздаваемый файл-компаньон альбома (обложка `folder.jpg`, плейлист
/// `playlist.m3u8`): имя (относительно корня альбома) + sha256 + размер.
public struct ManifestFile: Codable, Equatable, Sendable {
    public var fileName: String
    public var sha256: String
    public var fileSize: Int

    public init(fileName: String, sha256: String, fileSize: Int) {
        self.fileName = fileName
        self.sha256 = sha256
        self.fileSize = fileSize
    }
}

/// Обложка альбома — частный случай файла-компаньона. Псевдоним ради совместимости
/// исходников; на wire это тот же объект `{fileName, sha256, fileSize}`.
public typealias ManifestArtwork = ManifestFile

public extension ManifestAlbum {
    /// Уникальные физические файлы альбома, раздаваемые по сети: треки (**дедуп по
    /// `fileName`** — cue-образ делит один контейнер между N логическими треками,
    /// качаем/храним его один раз), затем обложка, плейлист и `extras` (`.cue`/`.log`).
    /// Каждый как `{fileName, sha, size}` — общая основа для дельта-плана, локальной
    /// sha-карты, счётчика файлов и keep-set чистки устаревших файлов на устройстве.
    /// Порядок стабильный (треки → обложка → плейлист → extras).
    var servableFiles: [ManifestFile] {
        var seen: Set<String> = []
        var files: [ManifestFile] = []
        func add(_ file: ManifestFile) {
            if seen.insert(file.fileName).inserted { files.append(file) }
        }
        for track in tracks {
            add(ManifestFile(fileName: track.fileName, sha256: track.sha256, fileSize: track.fileSize))
        }
        if let artwork { add(artwork) }
        if let playlist { add(playlist) }
        for extra in extras { add(extra) }
        return files
    }
}
