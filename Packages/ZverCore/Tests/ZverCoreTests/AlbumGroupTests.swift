import Foundation
import Testing
@testable import ZverCore

/// Каждый альбом — своя папка (как в реальной библиотеке): идентичность альбома —
/// это ПАПКА, а не тег. `folder` можно задать явно (для теста «две оцифровки одного
/// альбома в разных папках»); по умолчанию папка выводится из имени альбома, а
/// treки без альбома (orphan) кладутся в общий корень `/music`.
private func makeTrack(title: String, artist: String? = nil, album: String? = nil,
                       trackNumber: Int? = nil, discNumber: Int? = nil,
                       discLabel: String? = nil, folder: String? = nil,
                       sampleRate: Double = 44100, bitDepth: Int? = nil,
                       ext: String = "flac") -> Track {
    let dir = folder ?? album.flatMap { name in
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "/music/\(name)"
    } ?? "/music"
    return Track(url: URL(fileURLWithPath: "\(dir)/\(title).\(ext)"), title: title,
                 artist: artist, album: album, trackNumber: trackNumber,
                 discNumber: discNumber, discLabel: discLabel,
                 duration: 60, sampleRate: sampleRate, bitDepth: bitDepth)
}

@Suite struct AlbumGroupTests {
    @Test func hashableByIdEnablesValueBasedNavigation() {
        // Value-based навигация SwiftUI требует Hashable. Хэшируем по id (путь папки):
        // согласован с синтезированным ==, разные альбомы различимы в Set/пути стека.
        let a = AlbumGroup(id: "/music/A", album: "A", artist: nil,
                           tracks: [makeTrack(title: "t", album: "A")])
        let aSame = AlbumGroup(id: "/music/A", album: "A", artist: nil,
                               tracks: [makeTrack(title: "t", album: "A")])
        let b = AlbumGroup(id: "/music/B", album: "B", artist: nil,
                           tracks: [makeTrack(title: "t", album: "B")])

        #expect(a == aSame)                       // равны по значению…
        #expect(a.hashValue == aSame.hashValue)   // …и по хэшу (контракт Hashable)
        #expect(Set([a, aSame, b]).count == 2)    // разные id → разные элементы
    }

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

    @Test func sortsByDiscThenTrackNumberNotInterleaved() {
        // Регрессия «Mezzanine»: диск 2 нумерует треки заново (1..8), поэтому
        // сортировка ТОЛЬКО по trackNumber перемешивала бы диски
        // (d1t1, d2t1, d1t2, …). Порядок обязан быть: весь диск 1, затем диск 2.
        let tracks = [
            makeTrack(title: "Metal Banshee", album: "Mezzanine", trackNumber: 1, discNumber: 2, folder: "/m/Mezzanine"),
            makeTrack(title: "Angel",         album: "Mezzanine", trackNumber: 1, discNumber: 1, folder: "/m/Mezzanine"),
            makeTrack(title: "Teardrop",      album: "Mezzanine", trackNumber: 3, discNumber: 1, folder: "/m/Mezzanine"),
            makeTrack(title: "Angel Dust",    album: "Mezzanine", trackNumber: 2, discNumber: 2, folder: "/m/Mezzanine"),
            makeTrack(title: "Risingson",     album: "Mezzanine", trackNumber: 2, discNumber: 1, folder: "/m/Mezzanine"),
        ]

        let group = AlbumGroup.group(tracks)[0]

        #expect(group.tracks.map(\.title)
                == ["Angel", "Risingson", "Teardrop", "Metal Banshee", "Angel Dust"])
    }

    @Test func discSectionsSplitMultiDiscAlbum() {
        let tracks = [
            makeTrack(title: "D2T2", album: "X", trackNumber: 2, discNumber: 2, folder: "/m/X"),
            makeTrack(title: "D1T1", album: "X", trackNumber: 1, discNumber: 1, folder: "/m/X"),
            makeTrack(title: "D2T1", album: "X", trackNumber: 1, discNumber: 2, folder: "/m/X"),
            makeTrack(title: "D1T2", album: "X", trackNumber: 2, discNumber: 1, folder: "/m/X"),
        ]

        let group = AlbumGroup.group(tracks)[0]

        #expect(group.hasMultipleDiscs)
        let sections = group.discSections
        #expect(sections.map(\.number) == [1, 2])
        #expect(sections[0].tracks.map(\.title) == ["D1T1", "D1T2"])
        #expect(sections[1].tracks.map(\.title) == ["D2T1", "D2T2"])
    }

    @Test func discSubfoldersFoldIntoOneAlbumViaLabel() {
        // CD1/CD2 — подпапки-диски: метка диска совпадает с именем папки, поэтому
        // альбом ОДИН (корень), а не два. Секции показывают метки как есть.
        let tracks = [
            makeTrack(title: "T2", album: "Maxinquaye", trackNumber: 1, discNumber: 2,
                      discLabel: "CD2", folder: "/m/Maxinquaye/CD2"),
            makeTrack(title: "T1", album: "Maxinquaye", trackNumber: 1, discNumber: 1,
                      discLabel: "CD1", folder: "/m/Maxinquaye/CD1"),
            makeTrack(title: "T1b", album: "Maxinquaye", trackNumber: 2, discNumber: 1,
                      discLabel: "CD1", folder: "/m/Maxinquaye/CD1"),
        ]

        let groups = AlbumGroup.group(tracks)

        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.id == "/m/Maxinquaye")   // корень, а не /CD1 или /CD2
        #expect(group.hasMultipleDiscs)
        #expect(group.discSections.map(\.title) == ["CD1", "CD2"])
        #expect(group.discSections[0].tracks.map(\.title) == ["T1", "T1b"])
        #expect(group.discSections[1].tracks.map(\.title) == ["T2"])
    }

    @Test func tagOnlyDiscsShowNumberedTitlesWithoutClimbing() {
        // Диски из тега DISCNUMBER без папок (discLabel nil) — группируем по
        // фактической папке, заголовки «Диск N».
        let tracks = [
            makeTrack(title: "A", album: "X", trackNumber: 1, discNumber: 1, folder: "/m/X"),
            makeTrack(title: "B", album: "X", trackNumber: 1, discNumber: 2, folder: "/m/X"),
        ]

        let group = AlbumGroup.group(tracks)[0]

        #expect(group.id == "/m/X")
        #expect(group.hasMultipleDiscs)
        #expect(group.discSections.map(\.title) == ["Диск 1", "Диск 2"])
    }

    @Test func singleDiscAlbumHasOneSectionAndNoHeaders() {
        // Одно-дисковый (диск 1 или без тега) — одна секция, заголовки не нужны.
        let tracks = [
            makeTrack(title: "A", album: "Y", trackNumber: 1, discNumber: 1, folder: "/m/Y"),
            makeTrack(title: "B", album: "Y", trackNumber: 2, folder: "/m/Y"),   // disc nil → 1
        ]

        let group = AlbumGroup.group(tracks)[0]

        #expect(!group.hasMultipleDiscs)
        #expect(group.discSections.count == 1)
        #expect(group.discSections[0].number == 1)
        #expect(group.discSections[0].tracks.map(\.title) == ["A", "B"])
    }

    @Test func groupIdentityIsStableFolderPath() {
        // id группы — путь папки (для устойчивого ForEach при одинаковых названиях).
        let tracks = [makeTrack(title: "x", album: "Nimbus", trackNumber: 1, folder: "/music/Nimbus")]
        let groups = AlbumGroup.group(tracks)
        #expect(groups.count == 1)
        #expect(groups[0].id == "/music/Nimbus")
    }
}
