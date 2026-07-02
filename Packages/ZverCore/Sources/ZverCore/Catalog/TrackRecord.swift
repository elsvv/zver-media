import Foundation
import GRDB

/// Строка таблицы `track` каталога. Пути — относительные от Documents.
public struct TrackRecord: Codable, Equatable, Sendable,
                           FetchableRecord, PersistableRecord {
    public static let databaseTableName = "track"

    public var relativePath: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    /// Номер диска (1-based) для много-дисковых альбомов. nil — одно-дисковый.
    public var discNumber: Int?
    public var year: Int?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int?
    public var artworkFilePath: String?
    public var addedAt: Date
    /// Ярус хранения (этап 4). rawValue `FileState`; новые/импортированные
    /// треки — `local`. Колонка NOT NULL DEFAULT 'local'.
    public var fileState: String
    /// SHA-256, подтверждённый в облаке (метаданные ресурса). nil, пока трек
    /// не подтверждён в облаке. Гейт удаления локальной копии при offload.
    public var cloudSha: String?

    public init(relativePath: String, title: String, artist: String? = nil,
                album: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                year: Int? = nil, duration: Double, sampleRate: Double,
                bitDepth: Int? = nil, artworkFilePath: String? = nil,
                addedAt: Date = Date(),
                fileState: String = FileState.local.rawValue,
                cloudSha: String? = nil) {
        self.relativePath = relativePath
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.artworkFilePath = artworkFilePath
        self.addedAt = addedAt
        self.fileState = fileState
        self.cloudSha = cloudSha
    }

    /// Запись из доменного трека: метаданные берутся из `track`,
    /// пути задаются явно (вычисляются на стороне сканера).
    public init(track: Track, relativePath: String, artworkFilePath: String?,
                addedAt: Date = Date()) {
        self.init(relativePath: relativePath,
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  trackNumber: track.trackNumber,
                  discNumber: track.discNumber,
                  year: track.year,
                  duration: track.duration,
                  sampleRate: track.sampleRate,
                  bitDepth: track.bitDepth,
                  artworkFilePath: artworkFilePath,
                  addedAt: addedAt,
                  fileState: track.fileState.rawValue)
    }

    /// Доменный трек: относительные пути разворачиваются от Documents.
    public func track(documentsURL: URL) -> Track {
        Track(url: documentsURL.appendingPathComponent(relativePath),
              title: title,
              artist: artist,
              album: album,
              trackNumber: trackNumber,
              discNumber: discNumber,
              year: year,
              duration: duration,
              sampleRate: sampleRate,
              bitDepth: bitDepth,
              artworkFileURL: artworkFilePath.map { documentsURL.appendingPathComponent($0) },
              fileState: FileState(rawValue: fileState) ?? .local)
    }
}
