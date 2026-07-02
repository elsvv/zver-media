import Foundation
import GRDB

/// Строка таблицы `track` каталога. Пути — относительные от Documents.
public struct TrackRecord: Codable, Equatable, Sendable,
                           FetchableRecord, PersistableRecord {
    public static let databaseTableName = "track"

    /// Первичный ключ (стабильная идентичность). Обычный трек — `relativePath`;
    /// cue-трек — `"\(relativePath)#\(cueIndex)"`. Позволяет N cue-строкам с общим
    /// `relativePath` (контейнером) сосуществовать в каталоге.
    public var trackKey: String
    /// Относительный путь физического файла (контейнера). У N cue-строк совпадает.
    /// Ключ для файловых/облачных операций (наличие на диске, upload/download).
    public var relativePath: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    /// Номер диска (1-based) для много-дисковых альбомов. nil — одно-дисковый.
    public var discNumber: Int?
    /// Метка диска для отображения (`CD1`, `Side A`). nil — «Диск N» по номеру.
    public var discLabel: String?
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
    /// Номер cue-трека (1-based) внутри контейнера. nil — обычный трек.
    public var cueIndex: Int?
    /// Стартовый сэмпл диапазона трека в контейнере (sample-accurate). nil — обычный.
    public var startFrame: Int64?
    /// Число сэмплов диапазона трека. nil — обычный трек (файл целиком).
    public var frameCount: Int64?

    /// Вычисляет `trackKey` из пути контейнера и (для cue) номера трека.
    /// Единственный источник правды формы ключа — используется и в скане, и в миграции.
    public static func trackKey(relativePath: String, cueIndex: Int?) -> String {
        if let cueIndex {
            return "\(relativePath)#\(cueIndex)"
        }
        return relativePath
    }

    public init(relativePath: String, title: String, artist: String? = nil,
                album: String? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
                discLabel: String? = nil, year: Int? = nil, duration: Double,
                sampleRate: Double, bitDepth: Int? = nil, artworkFilePath: String? = nil,
                addedAt: Date = Date(),
                fileState: String = FileState.local.rawValue,
                cloudSha: String? = nil,
                cueIndex: Int? = nil, startFrame: Int64? = nil, frameCount: Int64? = nil) {
        self.trackKey = Self.trackKey(relativePath: relativePath, cueIndex: cueIndex)
        self.relativePath = relativePath
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.discLabel = discLabel
        self.year = year
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.artworkFilePath = artworkFilePath
        self.addedAt = addedAt
        self.fileState = fileState
        self.cloudSha = cloudSha
        self.cueIndex = cueIndex
        self.startFrame = startFrame
        self.frameCount = frameCount
    }

    /// Запись из доменного трека: метаданные и границы cue берутся из `track`,
    /// пути задаются явно (вычисляются на стороне сканера). `trackKey` собирается
    /// из `relativePath` + `cueIndex` (не из абсолютного `track.id`).
    public init(track: Track, relativePath: String, artworkFilePath: String?,
                addedAt: Date = Date()) {
        self.init(relativePath: relativePath,
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  trackNumber: track.trackNumber,
                  discNumber: track.discNumber,
                  discLabel: track.discLabel,
                  year: track.year,
                  duration: track.duration,
                  sampleRate: track.sampleRate,
                  bitDepth: track.bitDepth,
                  artworkFilePath: artworkFilePath,
                  addedAt: addedAt,
                  fileState: track.fileState.rawValue,
                  cueIndex: track.cueIndex,
                  startFrame: track.startFrame,
                  frameCount: track.frameCount)
    }

    /// Доменный трек: относительные пути разворачиваются от Documents.
    public func track(documentsURL: URL) -> Track {
        Track(url: documentsURL.appendingPathComponent(relativePath),
              title: title,
              artist: artist,
              album: album,
              trackNumber: trackNumber,
              discNumber: discNumber,
              discLabel: discLabel,
              year: year,
              duration: duration,
              sampleRate: sampleRate,
              bitDepth: bitDepth,
              artworkFileURL: artworkFilePath.map { documentsURL.appendingPathComponent($0) },
              fileState: FileState(rawValue: fileState) ?? .local,
              cueIndex: cueIndex,
              startFrame: startFrame,
              frameCount: frameCount)
    }
}
