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
    public var year: Int?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int?
    public var artworkFilePath: String?
    public var addedAt: Date

    public init(relativePath: String, title: String, artist: String? = nil,
                album: String? = nil, trackNumber: Int? = nil, year: Int? = nil,
                duration: Double, sampleRate: Double, bitDepth: Int? = nil,
                artworkFilePath: String? = nil, addedAt: Date = Date()) {
        self.relativePath = relativePath
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.year = year
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.artworkFilePath = artworkFilePath
        self.addedAt = addedAt
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
                  year: track.year,
                  duration: track.duration,
                  sampleRate: track.sampleRate,
                  bitDepth: track.bitDepth,
                  artworkFilePath: artworkFilePath,
                  addedAt: addedAt)
    }

    /// Доменный трек: относительные пути разворачиваются от Documents.
    public func track(documentsURL: URL) -> Track {
        Track(url: documentsURL.appendingPathComponent(relativePath),
              title: title,
              artist: artist,
              album: album,
              trackNumber: trackNumber,
              year: year,
              duration: duration,
              sampleRate: sampleRate,
              bitDepth: bitDepth,
              artworkFileURL: artworkFilePath.map { documentsURL.appendingPathComponent($0) })
    }
}
