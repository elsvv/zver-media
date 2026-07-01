import Foundation
import Testing
@testable import ZverCore

/// Каждый альбом — своя папка (как в реальной библиотеке): идентичность альбома —
/// это ПАПКА, а не тег. `folder` можно задать явно (для теста «две оцифровки одного
/// альбома в разных папках»); по умолчанию папка выводится из имени альбома, а
/// treки без альбома (orphan) кладутся в общий корень `/music`.
private func makeTrack(title: String, artist: String? = nil, album: String? = nil,
                       trackNumber: Int? = nil, folder: String? = nil,
                       sampleRate: Double = 44100, bitDepth: Int? = nil,
                       ext: String = "flac") -> Track {
    let dir = folder ?? album.flatMap { name in
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "/music/\(name)"
    } ?? "/music"
    return Track(url: URL(fileURLWithPath: "\(dir)/\(title).\(ext)"), title: title,
                 artist: artist, album: album, trackNumber: trackNumber,
                 duration: 60, sampleRate: sampleRate, bitDepth: bitDepth)
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

    @Test func distinctFoldersWithSameAlbumTagAreSeparateAlbums() {
        // Две оцифровки одного альбома, каждая в своей папке, но с ОДИНАКОВЫМ
        // тегом ALBUM. Раньше группировка по тегу сливала их в один альбом и
        // теряла версию. Теперь идентичность — папка: два разных альбома.
        let tracks = [
            makeTrack(title: "A1", album: "The Wall", trackNumber: 1,
                      folder: "/music/The Wall [1979]", bitDepth: 16),
            makeTrack(title: "A2", album: "The Wall", trackNumber: 2,
                      folder: "/music/The Wall [1979]", bitDepth: 16),
            makeTrack(title: "R1", album: "The Wall", trackNumber: 1,
                      folder: "/music/The Wall [2011 remaster]", bitDepth: 24),
        ]

        let groups = AlbumGroup.group(tracks)

        #expect(groups.count == 2)
        // Обе версии показывают тег-название, но это РАЗНЫЕ группы (разные папки).
        #expect(groups.allSatisfy { $0.album == "The Wall" })
        #expect(Set(groups.map(\.id)).count == 2)
        let original = groups.first { $0.id.contains("1979") }
        let remaster = groups.first { $0.id.contains("2011") }
        #expect(original?.tracks.map(\.title) == ["A1", "A2"])
        #expect(remaster?.tracks.map(\.title) == ["R1"])
    }

    @Test func tracksInSameFolderAreOneAlbumEvenWithDifferentTags() {
        // Одна папка = один альбом, даже если у части треков тег с опечаткой.
        // Отображаемое название — по большинству непустых тегов в папке.
        let tracks = [
            makeTrack(title: "01", album: "Kind of Blue", trackNumber: 1, folder: "/music/kob"),
            makeTrack(title: "02", album: "Kind of Blue", trackNumber: 2, folder: "/music/kob"),
            makeTrack(title: "03", album: "Kind of Bleu", trackNumber: 3, folder: "/music/kob"),
        ]

        let groups = AlbumGroup.group(tracks)

        #expect(groups.count == 1)
        #expect(groups[0].album == "Kind of Blue")   // большинство (2 из 3)
        #expect(groups[0].tracks.map(\.title) == ["01", "02", "03"])
    }

    @Test func sameAlbumTagSameFolderStaysOneAlbum() {
        // Не переусердствовать: одинаковый тег И одна папка — по-прежнему ОДИН
        // альбом (обычный кейс, версия только одна).
        let tracks = [
            makeTrack(title: "1", album: "Aurora", trackNumber: 1, folder: "/music/Aurora"),
            makeTrack(title: "2", album: "Aurora", trackNumber: 2, folder: "/music/Aurora"),
        ]

        let groups = AlbumGroup.group(tracks)

        #expect(groups.count == 1)
        #expect(groups[0].album == "Aurora")
        #expect(groups[0].tracks.count == 2)
    }

    @Test func groupIdentityIsStableFolderPath() {
        // id группы — путь папки (для устойчивого ForEach при одинаковых названиях).
        let tracks = [makeTrack(title: "x", album: "Nimbus", trackNumber: 1, folder: "/music/Nimbus")]
        let groups = AlbumGroup.group(tracks)
        #expect(groups.count == 1)
        #expect(groups[0].id == "/music/Nimbus")
    }
}
