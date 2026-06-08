import Foundation

/// DTO протокола пульта — данные плеера/библиотеки, которые iPhone шлёт Маку.
///
/// Это самостоятельные транспортные модели (по образцу `ManifestTrack`/`ManifestAlbum`
/// этапа 3): они НЕ зависят от `ZverCore.Track`/`AlbumGroup`, чтобы протокол можно
/// было кодировать/декодировать без модели приложения. Mac никогда не получает
/// локальные URL/файлы — только метадату, достаточную для UI и запуска альбома.

/// Состояние воспроизведения. Раздельный enum со строковым `rawValue` —
/// forward-compat: новое значение playback от будущей версии декодится в
/// `.unknown`, а не роняет весь декод (см. `RemoteCodec`).
public enum RemotePlayback: String, Codable, Equatable, Sendable {
    case idle
    case playing
    case paused
    /// Неизвестное будущей версии состояние — соединение не рвём.
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemotePlayback(rawValue: raw) ?? .unknown
    }
}

/// Трек в протоколе пульта: метадата для отображения и для запуска альбома
/// (`id` резолвится iPhone в локальный файл, Mac его не видит).
public struct RemoteTrack: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var duration: Double
    public var sampleRate: Int?
    public var bitDepth: Int?

    public init(id: String,
                title: String,
                artist: String? = nil,
                album: String? = nil,
                duration: Double,
                sampleRate: Int? = nil,
                bitDepth: Int? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }
}

/// Лёгкая запись альбома для списка библиотеки (без треков — те тянутся по
/// запросу `requestAlbumTracks`, чтобы не слать всю библиотеку зараз).
public struct RemoteAlbum: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String?
    public var year: Int?
    public var trackCount: Int

    public init(id: String,
                title: String,
                artist: String? = nil,
                year: Int? = nil,
                trackCount: Int) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.trackCount = trackCount
    }
}

/// Список альбомов библиотеки iPhone (отдаётся на коннект и при изменении каталога).
public struct RemoteLibrary: Codable, Equatable, Sendable {
    public var albums: [RemoteAlbum]

    public init(albums: [RemoteAlbum]) {
        self.albums = albums
    }
}

/// Снимок состояния плеера для пуша в пульт. `position` — секунды; Mac
/// интерполирует её между пушами сам (см. `RemoteStateDiff` — троттлинг позиции).
public struct RemotePlayerState: Codable, Equatable, Sendable {
    public var playback: RemotePlayback
    public var current: RemoteTrack?
    public var position: Double
    public var queue: [RemoteTrack]
    public var currentIndex: Int?

    public init(playback: RemotePlayback,
                current: RemoteTrack? = nil,
                position: Double,
                queue: [RemoteTrack],
                currentIndex: Int? = nil) {
        self.playback = playback
        self.current = current
        self.position = position
        self.queue = queue
        self.currentIndex = currentIndex
    }
}
