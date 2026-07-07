import Foundation

/// Компактная выжимка библиотеки и вкуса слушателя — вход для промпта.
///
/// Альбомы несут КОРОТКИЕ стабильные id (`A1`, `A2`, …); маппинг id → реальный
/// `albumKey` живёт у вызывающего (в аппе — `HomeFeedService`). Так модель
/// оперирует дешёвыми токенами-идентификаторами, а не длинными ключами, и не
/// может «сослаться» на альбом мимо словаря. Жанров/тегов тут нет намеренно —
/// характер музыки модель выводит сама (в файлах теги не читаем).
///
/// Все поля `Sendable`/`Equatable`; кортежи заменены мелкими структурами.
/// `Codable` не нужен — снапшот собирается в памяти и сериализуется в промпт
/// вручную (``HomeFeedPrompt``), а не через JSON.
public struct LibrarySnapshot: Sendable, Equatable {
    /// Один альбом библиотеки: короткий id + минимум метаданных для строки промпта.
    public struct AlbumEntry: Sendable, Equatable {
        /// Короткий id вида `A17` (уникален в пределах снапшота).
        public let id: String
        /// Артист (может быть `nil` — сборники/без тега).
        public let artist: String?
        /// Название альбома (обязательно).
        public let album: String
        /// Год издания, если известен.
        public let year: Int?

        public init(id: String, artist: String?, album: String, year: Int?) {
            self.id = id
            self.artist = artist
            self.album = album
            self.year = year
        }
    }

    /// Артист + число прослушиваний (замена кортежа `(name, plays)`).
    public struct ArtistPlays: Sendable, Equatable {
        public let name: String
        public let plays: Int
        public init(name: String, plays: Int) {
            self.name = name
            self.plays = plays
        }
    }

    /// Альбом (по короткому id) + число прослушиваний (замена кортежа `(id, plays)`).
    public struct AlbumPlays: Sendable, Equatable {
        public let id: String
        public let plays: Int
        public init(id: String, plays: Int) {
            self.id = id
            self.plays = plays
        }
    }

    /// Все альбомы библиотеки (уже обрезанные вызывающим до бюджета промпта).
    public let albums: [AlbumEntry]
    /// Топ-артисты по прослушиваниям (по убыванию).
    public let topArtists: [ArtistPlays]
    /// Топ-альбомы по прослушиваниям (по убыванию), по короткому id.
    public let topAlbums: [AlbumPlays]
    /// Id избранных альбомов.
    public let favoriteAlbumIds: [String]
    /// Названия любимых треков (id треков в снапшоте нет — только заголовки).
    public let favoriteTrackTitles: [String]
    /// Id недавно прослушанных альбомов (свежие — первыми).
    public let recentlyPlayedIds: [String]
    /// Id недавно добавленных альбомов (свежие — первыми).
    public let recentlyAddedIds: [String]

    public init(
        albums: [AlbumEntry],
        topArtists: [ArtistPlays],
        topAlbums: [AlbumPlays],
        favoriteAlbumIds: [String],
        favoriteTrackTitles: [String],
        recentlyPlayedIds: [String],
        recentlyAddedIds: [String]
    ) {
        self.albums = albums
        self.topArtists = topArtists
        self.topAlbums = topAlbums
        self.favoriteAlbumIds = favoriteAlbumIds
        self.favoriteTrackTitles = favoriteTrackTitles
        self.recentlyPlayedIds = recentlyPlayedIds
        self.recentlyAddedIds = recentlyAddedIds
    }

    /// Множество валидных id альбомов — для ``HomeFeedParser`` (отсев галлюцинаций).
    public var validAlbumIds: Set<String> {
        Set(albums.map(\.id))
    }
}
