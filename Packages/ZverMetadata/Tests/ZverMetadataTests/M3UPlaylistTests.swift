import Testing
import Foundation
@testable import ZverMetadata

@Suite struct M3UPlaylistTests {
    @Test func parsesPlainFileNamesInOrder() {
        let content = "A1. 2 + 2 = 5.flac\nA2. Sit Down.flac\nB1. Backdrifts.flac\n"
        #expect(M3UPlaylist.entries(from: content) == [
            "A1. 2 + 2 = 5.flac", "A2. Sit Down.flac", "B1. Backdrifts.flac",
        ])
        let order = M3UPlaylist.order(from: content)
        #expect(order["a1. 2 + 2 = 5.flac"] == 1)
        #expect(order["a2. sit down.flac"] == 2)
        #expect(order["b1. backdrifts.flac"] == 3)
    }

    @Test func stripsUTF8BOM() {
        // Реальный Playlist.m3u Radiohead начинается с BOM (﻿).
        let content = "\u{FEFF}A1.flac\nA2.flac\n"
        #expect(M3UPlaylist.entries(from: content) == ["A1.flac", "A2.flac"])
    }

    @Test func skipsCommentsAndBlankLines() {
        let content = "#EXTM3U\n\nA1.flac\n#EXTINF:215,Radiohead - 2+2=5\nA2.flac\n"
        #expect(M3UPlaylist.entries(from: content) == ["A1.flac", "A2.flac"])
    }

    @Test func trimsCRLFAndSurroundingWhitespace() {
        let content = "A1.flac\r\n  A2.flac  \r\nB1.flac\r"
        #expect(M3UPlaylist.entries(from: content) == ["A1.flac", "A2.flac", "B1.flac"])
    }

    @Test func usesLastPathComponentForReferencesWithDirectories() {
        // Записи могут быть относительными путями (в т.ч. с обратным слэшем Windows).
        let content = "Disc 1/A1.flac\nDisc 2\\B1.flac\n"
        #expect(M3UPlaylist.entries(from: content) == ["A1.flac", "B1.flac"])
    }

    @Test func orderIsCaseInsensitiveAndFirstOccurrenceWins() {
        let content = "Track.flac\ntrack.flac\n"
        let order = M3UPlaylist.order(from: content)
        #expect(order["track.flac"] == 1)
    }

    @Test func emptyOrCommentOnlyContentGivesNoEntries() {
        #expect(M3UPlaylist.entries(from: "").isEmpty)
        #expect(M3UPlaylist.entries(from: "#EXTM3U\n\n  \n").isEmpty)
    }

    // MARK: - Пути и диски (папки CD1/CD2, стороны винила)

    @Test func parsePreservesRelativePathAndDisc() {
        let content = "CD1/01 - Overcome.flac\nCD1/02 - Ponderosa.flac\nCD2/01 - Strugglin'.flac\n"
        let entries = M3UPlaylist.parse(from: content)
        #expect(entries.map(\.path) == [
            "CD1/01 - Overcome.flac", "CD1/02 - Ponderosa.flac", "CD2/01 - Strugglin'.flac",
        ])
        #expect(entries.map(\.fileName) == [
            "01 - Overcome.flac", "02 - Ponderosa.flac", "01 - Strugglin'.flac",
        ])
        #expect(entries.map(\.disc) == ["CD1", "CD1", "CD2"])
    }

    @Test func rootLevelEntriesHaveNilDisc() {
        let entries = M3UPlaylist.parse(from: "01.flac\n02.flac\n")
        #expect(entries.allSatisfy { $0.disc == nil })
        #expect(entries.map(\.path) == ["01.flac", "02.flac"])
    }

    @Test func discMapGivesLabelOrdinalAndPerDiscPosition() throws {
        let content = """
        CD1/01 - Overcome.flac
        CD1/02 - Ponderosa.flac
        CD2/01 - Strugglin'.flac
        CD2/02 - Aftermath.flac
        """
        let m = M3UPlaylist.discMap(from: content)
        let a = try #require(m["cd1/01 - overcome.flac"])
        #expect(a.discLabel == "CD1")
        #expect(a.discOrdinal == 1)
        #expect(a.position == 1)
        #expect(a.globalPosition == 1)
        let b = try #require(m["cd1/02 - ponderosa.flac"])
        #expect(b.discOrdinal == 1)
        #expect(b.position == 2)
        let c = try #require(m["cd2/01 - strugglin'.flac"])
        #expect(c.discLabel == "CD2")
        #expect(c.discOrdinal == 2)
        #expect(c.position == 1)        // нумерация трека перезапускается на диске
        #expect(c.globalPosition == 3)
    }

    @Test func discMapNormalizesWindowsSeparatorAndDotSlash() throws {
        let m = M3UPlaylist.discMap(from: "./CD1\\01.flac\nCD1/02.flac\n")
        let a = try #require(m["cd1/01.flac"])
        #expect(a.discLabel == "CD1")
        #expect(a.position == 1)
        let b = try #require(m["cd1/02.flac"])
        #expect(b.position == 2)
    }
}
