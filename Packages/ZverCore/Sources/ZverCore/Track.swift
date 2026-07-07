import Foundation

public struct Track: Identifiable, Equatable, Hashable, Sendable {
    /// Стабильный `trackKey`: обычный трек — `url.path`; cue-трек —
    /// `"\(url.path)#\(cueIndex)"` (различает N логических треков в одном `.flac`).
    public let id: String
    /// Контейнер: путь физического аудиофайла. У cue-треков N штук делят один `url`.
    public var url: URL
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    /// Номер диска в много-дисковом альбоме (1-based). nil/1 — одно-дисковый.
    /// Определяет порядок и деление на секции на экране альбома.
    public var discNumber: Int?
    /// Метка диска для отображения (`CD1`, `Side A`) из папки/плейлиста. nil —
    /// показываем «Диск N» по discNumber. Если метка совпадает с именем папки трека,
    /// эта папка-диск «сворачивается» в альбом при группировке (см. `AlbumGroup`).
    public var discLabel: String?
    public var year: Int?
    public var duration: Double    // секунды
    public var sampleRate: Double  // Гц
    public var bitDepth: Int?
    public var fileExtension: String
    public var artworkFileURL: URL?   // обложка из файла в папке (folder.jpg и т.п.)
    /// Когда трек добавлен в каталог (из строки `track.addedAt`). nil, если трек
    /// собран не из каталога (напр. свежесканированный до сверки). Питает секцию
    /// «Недавно добавленные» (recency альбома = max addedAt его треков).
    public var addedAt: Date?
    public var fileState: FileState   // ярус хранения локально/в облаке (этап 4)
    /// Номер cue-трека (1-based) внутри контейнерного `.flac` (image+cue). nil —
    /// обычный трек (1 файл = 1 трек). Входит в `id` для различения соседей.
    public var cueIndex: Int?
    /// Стартовый сэмпл диапазона трека в контейнере (sample-accurate, побитово).
    /// nil у обычных треков. Границы храним в сэмплах, не в секундах.
    public var startFrame: Int64?
    /// Число сэмплов диапазона трека (до старта следующего/конца файла). nil у обычных.
    public var frameCount: Int64?

    /// Трек-«вырезка» из общего `.flac` (image+cue): заданы границы сэмплов.
    public var isCueTrack: Bool { startFrame != nil }

    public init(url: URL, title: String, artist: String? = nil, album: String? = nil,
                trackNumber: Int? = nil, discNumber: Int? = nil, discLabel: String? = nil,
                year: Int? = nil, duration: Double, sampleRate: Double, bitDepth: Int? = nil,
                artworkFileURL: URL? = nil, addedAt: Date? = nil,
                fileState: FileState = .local,
                cueIndex: Int? = nil, startFrame: Int64? = nil, frameCount: Int64? = nil) {
        if let cueIndex {
            self.id = "\(url.path)#\(cueIndex)"
        } else {
            self.id = url.path
        }
        self.url = url
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
        self.fileExtension = url.pathExtension.lowercased()
        self.artworkFileURL = artworkFileURL
        self.addedAt = addedAt
        self.fileState = fileState
        self.cueIndex = cueIndex
        self.startFrame = startFrame
        self.frameCount = frameCount
    }
}
