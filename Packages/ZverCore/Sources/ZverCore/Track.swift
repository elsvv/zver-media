import Foundation

public struct Track: Identifiable, Equatable, Hashable, Sendable {
    public let id: String          // стабильный: путь файла
    public var url: URL
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var duration: Double    // секунды
    public var sampleRate: Double  // Гц
    public var bitDepth: Int?
    public var fileExtension: String
    public var artworkFileURL: URL?   // обложка из файла в папке (folder.jpg и т.п.)
    public var fileState: FileState   // ярус хранения локально/в облаке (этап 4)

    public init(url: URL, title: String, artist: String? = nil, album: String? = nil,
                trackNumber: Int? = nil, year: Int? = nil, duration: Double,
                sampleRate: Double, bitDepth: Int? = nil, artworkFileURL: URL? = nil,
                fileState: FileState = .local) {
        self.id = url.path
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.year = year
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileExtension = url.pathExtension.lowercased()
        self.artworkFileURL = artworkFileURL
        self.fileState = fileState
    }
}
