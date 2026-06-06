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
}
