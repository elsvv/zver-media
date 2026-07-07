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
    /// Агрегат облачного состояния по трекам альбома: `local|backedUp|remote|mixed`.
    /// Аддитивное опциональное поле — синтезированный декод использует
    /// decodeIfPresent, поэтому старый JSON без ключа декодится в `nil`.
    public var cloudState: String?

    public init(id: String,
                title: String,
                artist: String? = nil,
                year: Int? = nil,
                trackCount: Int,
                cloudState: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.trackCount = trackCount
        self.cloudState = cloudState
    }
}

/// Агрегированный прогресс headless-импорта на iPhone (запущенного командой
/// `startImport` с Мака). Один статус на весь прогон, а не пофайловый спам —
/// Mac рисует стадию и общую долю (см. `RemotePayload.importStatus`).
public struct RemoteImportStatus: Codable, Equatable, Sendable {
    /// Стадия импорта. Раздельный enum со строковым `rawValue` — forward-compat:
    /// новая стадия будущей версии декодится в `.unknown`, а не роняет весь
    /// декод (как `RemotePlayback`).
    public enum Phase: String, Codable, Equatable, Sendable {
        case idle
        case downloading
        case done
        case failed
        /// Неизвестная будущей версии стадия — соединение не рвём.
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Phase(rawValue: raw) ?? .unknown
        }
    }

    public var phase: Phase
    /// Какой альбом сейчас качается (для UI); обычно nil вне `.downloading`.
    public var albumTitle: String?
    public var completedAlbums: Int
    public var totalAlbums: Int
    /// Общий прогресс 0…1.
    public var fraction: Double
    /// Текст ошибки для `.failed`.
    public var message: String?

    public init(phase: Phase,
                albumTitle: String? = nil,
                completedAlbums: Int,
                totalAlbums: Int,
                fraction: Double,
                message: String? = nil) {
        self.phase = phase
        self.albumTitle = albumTitle
        self.completedAlbums = completedAlbums
        self.totalAlbums = totalAlbums
        self.fraction = fraction
        self.message = message
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
    /// Каноничный id альбома ТЕКУЩЕГО трека — тот же, что в `RemoteLibrary`
    /// (id ГРУППЫ каталога, а не реконструкция из тегов трека: у сборников/VA
    /// артист трека ≠ артисту группы, и ключ обложки now-playing иначе
    /// разошёлся бы с гридом библиотеки). Аддитивно: nil от старых телефонов.
    public var currentAlbumId: String?

    public init(playback: RemotePlayback,
                current: RemoteTrack? = nil,
                position: Double,
                queue: [RemoteTrack],
                currentIndex: Int? = nil,
                currentAlbumId: String? = nil) {
        self.playback = playback
        self.current = current
        self.position = position
        self.queue = queue
        self.currentIndex = currentIndex
        self.currentAlbumId = currentAlbumId
    }
}
