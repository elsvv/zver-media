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

    public init(url: URL, title: String, artist: String? = nil, album: String? = nil,
                trackNumber: Int? = nil, year: Int? = nil, duration: Double,
                sampleRate: Double, bitDepth: Int? = nil) {
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
    }
}
