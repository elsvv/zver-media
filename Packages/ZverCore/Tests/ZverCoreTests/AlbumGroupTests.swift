import Foundation
import Testing
@testable import ZverCore

private func makeTrack(title: String, artist: String? = nil, album: String? = nil,
                       trackNumber: Int? = nil) -> Track {
    Track(url: URL(fileURLWithPath: "/t/\(title).flac"), title: title, artist: artist,
          album: album, trackNumber: trackNumber, duration: 60, sampleRate: 44100)
}

@Suite struct AlbumGroupTests {
    @Test func groupsTracksByAlbumSortedByTrackNumber() {
        // Перемешанный вход: два альбома + трек без альбома
        let tracks = [
            makeTrack(title: "B1", artist: "Боб", album: "Borealis", trackNumber: 1),
            makeTrack(title: "A2", artist: "Аня", album: "Aurora", trackNumber: 2),
            makeTrack(title: "Без номера", artist: "Боб", album: "Borealis", trackNumber: nil),
            makeTrack(title: "A1", artist: "Аня", album: "Aurora", trackNumber: 1),
            makeTrack(title: "Сирота", artist: nil, album: nil, trackNumber: 7),
        ]

        let groups = AlbumGroup.group(tracks)

        // Альбомы по алфавиту, безальбомные — в хвосте
        #expect(groups.map(\.album) == ["Aurora", "Borealis", "Без альбома"])

        // Внутри альбома: по trackNumber, nil — в конец
        #expect(groups[0].tracks.map(\.title) == ["A1", "A2"])
        #expect(groups[1].tracks.map(\.title) == ["B1", "Без номера"])
        #expect(groups[2].tracks.map(\.title) == ["Сирота"])

        // Артист группы — артист первого трека
        #expect(groups[0].artist == "Аня")
        #expect(groups[1].artist == "Боб")
        #expect(groups[2].artist == nil)
    }

    @Test func emptyInputProducesNoGroups() {
        #expect(AlbumGroup.group([]) == [])
    }

    @Test func sortsAlbumsAndTitlesAlphabeticallyIgnoringCase() {
        // Сырое `<` поставило бы "Zebra" раньше "abbey road" (код-поинты),
        // а "Beta" раньше "alpha" в тай-брейке по title.
        let tracks = [
            makeTrack(title: "Z1", album: "Zebra", trackNumber: 1),
            makeTrack(title: "a1", album: "abbey road", trackNumber: 1),
            makeTrack(title: "Beta", album: "Mixed"),
            makeTrack(title: "alpha", album: "Mixed"),
        ]

        let groups = AlbumGroup.group(tracks)

        #expect(groups.map(\.album) == ["abbey road", "Mixed", "Zebra"])
        #expect(groups[1].tracks.map(\.title) == ["alpha", "Beta"])
    }

    @Test func emptyOrWhitespaceAlbumFallsIntoNoAlbumGroup() {
        // Теги вида ALBUM= нередко содержат пустую строку — это не альбом.
        let tracks = [
            makeTrack(title: "Пустой", album: "", trackNumber: 1),
            makeTrack(title: "Пробельный", album: "   ", trackNumber: 2),
            makeTrack(title: "Настоящий", album: "Real", trackNumber: 1),
        ]

        let groups = AlbumGroup.group(tracks)

        #expect(groups.map(\.album) == ["Real", AlbumGroup.noAlbumTitle])
        #expect(groups[1].tracks.map(\.title) == ["Пустой", "Пробельный"])
    }
}
