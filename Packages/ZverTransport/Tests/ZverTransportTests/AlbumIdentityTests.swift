import Testing
import Foundation
@testable import ZverTransport

@Suite struct AlbumIdentityTests {
    @Test func deterministicSameInputSameOutput() {
        let a = AlbumIdentity.folderName(artist: "Radiohead", title: "In Rainbows", year: 2007)
        let b = AlbumIdentity.folderName(artist: "Radiohead", title: "In Rainbows", year: 2007)
        #expect(a == b)
    }

    @Test func fullFormatArtistTitleYear() {
        let name = AlbumIdentity.folderName(artist: "Radiohead", title: "In Rainbows", year: 2007)
        #expect(name == "Radiohead - In Rainbows (2007)")
    }

    @Test func nilYearOmitsParens() {
        let name = AlbumIdentity.folderName(artist: "Radiohead", title: "In Rainbows", year: nil)
        #expect(name == "Radiohead - In Rainbows")
    }

    @Test func nilArtistOmitsArtistPrefix() {
        let name = AlbumIdentity.folderName(artist: nil, title: "Mixtape", year: 2020)
        #expect(name == "Mixtape (2020)")
    }

    @Test func emptyArtistTreatedAsNil() {
        let name = AlbumIdentity.folderName(artist: "   ", title: "Solo", year: nil)
        #expect(name == "Solo")
    }

    @Test func sanitizesPathSeparators() {
        // / и : небезопасны для файловой системы (особенно HFS+/APFS, где ':'
        // исторически разделитель) — заменяем, не оставляем «голыми».
        let name = AlbumIdentity.folderName(artist: "AC/DC", title: "Back: In Black", year: 1980)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(name.contains("1980"))
    }

    @Test func stripsControlCharacters() {
        let name = AlbumIdentity.folderName(artist: "A\u{0007}B", title: "T\nX", year: nil)
        #expect(!name.contains("\u{0007}"))
        #expect(!name.contains("\n"))
    }

    @Test func collapsesWhitespace() {
        let name = AlbumIdentity.folderName(artist: "The    Band", title: "Big   Title", year: nil)
        #expect(!name.contains("  "))
        #expect(name == "The Band - Big Title")
    }

    @Test func trimsLeadingTrailingWhitespace() {
        let name = AlbumIdentity.folderName(artist: "  Artist  ", title: "  Title  ", year: nil)
        #expect(name == "Artist - Title")
    }

    @Test func emptyTitleStillProducesNonEmptyName() {
        let name = AlbumIdentity.folderName(artist: nil, title: "", year: nil)
        #expect(!name.isEmpty)
    }

    @Test func reuploadOfSameAlbumYieldsSameIdNoDuplicates() {
        // Перезаливка → тот же albumId → обновление на месте.
        let first = AlbumIdentity.folderName(artist: "Portishead", title: "Dummy", year: 1994)
        let second = AlbumIdentity.folderName(artist: "Portishead", title: "Dummy", year: 1994)
        #expect(first == second)
    }
}
