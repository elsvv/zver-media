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
}
