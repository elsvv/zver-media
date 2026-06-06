import Foundation

/// Группа треков одного альбома.
public struct AlbumGroup: Equatable, Sendable {
    public static let noAlbumTitle = "Без альбома"

    public let album: String
    public let artist: String?     // артист первого трека (MVP)
    public let tracks: [Track]

    public init(album: String, artist: String?, tracks: [Track]) {
        self.album = album
        self.artist = artist
        self.tracks = tracks
    }

    /// Группирует треки по альбомам: альбомы по алфавиту (как в Finder,
    /// без учёта регистра), треки без альбома — в группу «Без альбома» в конце.
    /// Пустой или пробельный тег альбома считается отсутствующим. Внутри альбома
    /// сортировка по trackNumber (nil — в конец), затем по title.
    public static func group(_ tracks: [Track]) -> [AlbumGroup] {
        let byAlbum = Dictionary(grouping: tracks) { normalizedAlbum($0.album) }

        func makeGroup(album: String, tracks: [Track]) -> AlbumGroup {
            let sorted = tracks.sorted { lhs, rhs in
                switch (lhs.trackNumber, rhs.trackNumber) {
                case let (l?, r?) where l != r: return l < r
                case (.some, .none): return true
                case (.none, .some): return false
                default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
            return AlbumGroup(album: album, artist: sorted.first?.artist, tracks: sorted)
        }

        var groups = byAlbum
            .compactMap { album, tracks in album.map { (album: $0, tracks: tracks) } }
            .sorted { $0.album.localizedStandardCompare($1.album) == .orderedAscending }
            .map(makeGroup)

        if let orphans = byAlbum[nil] {
            groups.append(makeGroup(album: noAlbumTitle, tracks: orphans))
        }
        return groups
    }

    /// Пустая или пробельная строка альбома — это отсутствие альбома.
    private static func normalizedAlbum(_ album: String?) -> String? {
        guard let album,
              !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return album
    }
}
