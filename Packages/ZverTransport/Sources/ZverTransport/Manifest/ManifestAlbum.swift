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
    public var tracks: [ManifestTrack]

    public init(id: String,
                title: String,
                artist: String? = nil,
                year: Int? = nil,
                artwork: ManifestArtwork? = nil,
                tracks: [ManifestTrack]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.artwork = artwork
        self.tracks = tracks
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

/// Обложка альбома как отдельный раздаваемый файл (например `folder.jpg`).
public struct ManifestArtwork: Codable, Equatable, Sendable {
    public var fileName: String
    public var sha256: String
    public var fileSize: Int

    public init(fileName: String, sha256: String, fileSize: Int) {
        self.fileName = fileName
        self.sha256 = sha256
        self.fileSize = fileSize
    }
}
