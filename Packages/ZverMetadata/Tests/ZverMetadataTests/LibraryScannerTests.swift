import Testing
import Foundation
@testable import ZverMetadata

@Suite struct LibraryScannerTests {
    @Test func findsAudioRecursivelyIgnoringJunk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом A")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try fm.copyItem(at: fixture("alac.m4a"), to: tmp.appendingPathComponent("solo.m4a"))
        try Data("мусор".utf8).write(to: sub.appendingPathComponent("readme.txt"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 2)
        #expect(infos.allSatisfy { ["flac", "m4a"].contains($0.url.pathExtension) })
        #expect(infos.map(\.url.path) == infos.map(\.url.path).sorted())
    }
    @Test func scanThrowsWhenDirectoryMissing() async {
        // Сбой перечисления корня (директории нет/нечитаема) — реальная
        // ошибка, а не «пустая библиотека»: иначе сверка с каталогом
        // стёрла бы все треки и плейлисты.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        await #expect(throws: (any Error).self) {
            _ = try await LibraryScanner.scan(directory: missing)
        }
    }
    @Test func emptyDirGivesEmptyResult() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let result = try await LibraryScanner.scan(directory: tmp)
        #expect(result.isEmpty)
    }
    @Test func skipsBrokenAudioFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: fixture("notags.flac"), to: tmp.appendingPathComponent("ok.flac"))
        try Data("не аудио, просто мусор".utf8).write(to: tmp.appendingPathComponent("broken.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.url.lastPathComponent == "ok.flac")
    }
    @Test func untaggedFileInSubfolderGetsAlbumFromFolderName() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Мой альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.album == "Мой альбом")
    }
    @Test func untaggedFileInScanRootKeepsNilAlbum() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: tmp.appendingPathComponent("notags.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.album == nil)
    }
    @Test func taggedAlbumWinsOverFolderName() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Не альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.album == "Фикстуры")
    }
    @Test func untaggedTrackPicksFolderJpgAsArtwork() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Radiohead - In Rainbows (2007) [24-44.1 WEB FLAC]")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: sub.appendingPathComponent("folder.jpg"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.artworkData == nil)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "folder.jpg")
    }
    @Test func coverNameWinsOverFolderCaseInsensitively() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: sub.appendingPathComponent("folder.jpg"))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sub.appendingPathComponent("Cover.PNG"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "Cover.PNG")
    }
    @Test func embeddedArtworkWinsOverFolderFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: sub.appendingPathComponent("folder.jpg"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.artworkData != nil)
        #expect(infos.first?.artworkFileURL == nil)
    }

    // MARK: - S3-7 sidecar overlay

    private func writeSidecar(_ json: String, into folder: URL) throws {
        try Data(json.utf8).write(
            to: folder.appendingPathComponent(AlbumSidecar.fileName))
    }

    @Test func sidecarOverridesTagsForTrack() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Папка")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))
        try writeSidecar("""
        {"version":1,"tracks":{"notags.flac":{
          "title":"Правленый заголовок",
          "artist":"Правленый исполнитель",
          "album":"Правленый альбом"}}}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.title == "Правленый заголовок")
        #expect(infos.first?.artist == "Правленый исполнитель")
        #expect(infos.first?.album == "Правленый альбом")
    }

    @Test func sidecarYearAndTrackNumberOverrideTags() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Папка")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // tagged_16_44.flac имеет встроенные теги — override должен победить.
        try FileManager.default.copyItem(
            at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try writeSidecar("""
        {"version":1,"tracks":{"01.flac":{"year":1999,"trackNumber":7}}}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.year == 1999)
        #expect(infos.first?.trackNumber == 7)
    }

    @Test func rootPlaylistDefinesDiscsAcrossSubfolders() async throws {
        // Структура рипа: <корень>/{CD1,CD2}/*.flac + playlist.m3u8 + cover.jpg.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let root = tmp.appendingPathComponent("Maxinquaye")
        let cd1 = root.appendingPathComponent("CD1")
        let cd2 = root.appendingPathComponent("CD2")
        try FileManager.default.createDirectory(at: cd1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cd2, withIntermediateDirectories: true)
        // notags.flac — без встроенной обложки, чтобы проверить обложку из корня.
        let fx = fixture("notags.flac")
        try FileManager.default.copyItem(at: fx, to: cd1.appendingPathComponent("a.flac"))
        try FileManager.default.copyItem(at: fx, to: cd1.appendingPathComponent("b.flac"))
        try FileManager.default.copyItem(at: fx, to: cd2.appendingPathComponent("c.flac"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("cover.jpg"))
        try Data("CD1/a.flac\nCD1/b.flac\nCD2/c.flac\n".utf8)
            .write(to: root.appendingPathComponent("playlist.m3u8"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        func info(_ name: String) throws -> AudioFileInfo {
            try #require(infos.first { $0.url.lastPathComponent == name })
        }
        #expect(infos.count == 3)

        let a = try info("a.flac")
        #expect(a.discLabel == "CD1")
        #expect(a.discNumber == 1)
        #expect(a.trackNumber == 1)
        // Нет тега альбома → имя КОРНЯ (не подпапки-диска).
        #expect(a.album == "Maxinquaye")
        // Обложка из корня доезжает до треков в подпапках.
        #expect(a.artworkFileURL?.lastPathComponent == "cover.jpg")

        let b = try info("b.flac")
        #expect(b.discLabel == "CD1")
        #expect(b.trackNumber == 2)      // номер внутри диска

        let c = try info("c.flac")
        #expect(c.discLabel == "CD2")
        #expect(c.discNumber == 2)
        #expect(c.trackNumber == 1)      // диск 2 нумерует с 1
        #expect(c.artworkFileURL?.lastPathComponent == "cover.jpg")
    }

    @Test func subfolderDiscsWithoutPlaylistUseFolderNameAsLabel() async throws {
        // Подпапки-диски без плейлиста: метка = имя подпапки, порядок — натуральный.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let root = tmp.appendingPathComponent("Album")
        let cd1 = root.appendingPathComponent("CD1")
        let cd2 = root.appendingPathComponent("CD2")
        try FileManager.default.createDirectory(at: cd1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cd2, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: root.appendingPathComponent("cover.jpg"))
        let fx = fixture("notags.flac")
        try FileManager.default.copyItem(at: fx, to: cd1.appendingPathComponent("x.flac"))
        try FileManager.default.copyItem(at: fx, to: cd2.appendingPathComponent("y.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        let x = try #require(infos.first { $0.url.lastPathComponent == "x.flac" })
        let y = try #require(infos.first { $0.url.lastPathComponent == "y.flac" })
        #expect(x.discLabel == "CD1")
        #expect(x.discNumber == 1)
        #expect(y.discLabel == "CD2")
        #expect(y.discNumber == 2)
    }

    @Test func sidecarDiscNumberOverridesTag() async throws {
        // Рип без DISCNUMBER, но альбом много-дисковый: правка с Мака задаёт диск.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Папка")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try writeSidecar("""
        {"version":1,"tracks":{"01.flac":{"discNumber":2}}}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.discNumber == 2)
    }

    @Test func sidecarArtworkFileNameWinsOverEmbedded() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // tagged_16_44.flac имеет встроенную обложку.
        try FileManager.default.copyItem(
            at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: sub.appendingPathComponent("edited.jpg"))
        try writeSidecar("""
        {"version":1,"artworkFileName":"edited.jpg","tracks":{}}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        // Контракт сканера: при наличии встроенной обложки И sidecar-обложки
        // сканер отдаёт ОБА источника — artworkData (встроенная) остаётся,
        // artworkFileURL указывает на правленый файл. Этого достаточно, чтобы
        // показ (S3-11, ArtworkLoader на стороне iOS) мог предпочесть override.
        #expect(infos.first?.artworkData != nil)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "edited.jpg")
    }

    @Test func sidecarArtworkOnlyWithoutTracksKeyApplies() async throws {
        // Правка только обложки на Маке: sidecar без ключа `tracks` вовсе.
        // Раньше такой sidecar не декодировался (keyNotFound) и молча
        // отбрасывался — обложка не подхватывалась. Теперь должен примениться.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: sub.appendingPathComponent("edited.jpg"))
        try writeSidecar("""
        {"version":1,"artworkFileName":"edited.jpg"}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "edited.jpg")
    }

    @Test func sidecarJSONNotScannedAsAudio() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))
        try writeSidecar("""
        {"version":1,"tracks":{}}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.url.lastPathComponent == "notags.flac")
    }

    @Test func brokenSidecarFallsBackToTags() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Мой альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))
        try writeSidecar("это {{ не валидный json", into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        // Скан не падает; поведение этапа 2: album из имени папки.
        #expect(infos.count == 1)
        #expect(infos.first?.album == "Мой альбом")
        #expect(infos.first?.title == "notags")
    }

    // MARK: - M3U playlist ordering

    private func writePlaylist(_ text: String, named name: String = "Playlist.m3u", into folder: URL) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    @Test func playlistAssignsTrackNumbersByPosition() async throws {
        // notags.flac не имеет TRACKNUMBER → без плейлиста trackNumber == nil.
        // Имена подобраны так, что алфавитный порядок ОБРАТЕН порядку плейлиста.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: fixture("notags.flac"), to: sub.appendingPathComponent("zebra.flac"))
        try fm.copyItem(at: fixture("notags.flac"), to: sub.appendingPathComponent("alpha.flac"))
        try writePlaylist("zebra.flac\nalpha.flac\n", into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        let zebra = infos.first { $0.url.lastPathComponent == "zebra.flac" }
        let alpha = infos.first { $0.url.lastPathComponent == "alpha.flac" }
        #expect(zebra?.trackNumber == 1)
        #expect(alpha?.trackNumber == 2)
    }

    @Test func playlistOverridesFileTagTrackNumber() async throws {
        // Две копии одного фикстура с ОДИНАКОВЫМ тегом trackNumber. Плейлист задаёт
        // им разные позиции (2 и 1) — значит число пришло из m3u, а не из тега.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("one.flac"))
        try fm.copyItem(at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("two.flac"))
        try writePlaylist("two.flac\none.flac\n", into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.first { $0.url.lastPathComponent == "two.flac" }?.trackNumber == 1)
        #expect(infos.first { $0.url.lastPathComponent == "one.flac" }?.trackNumber == 2)
    }

    @Test func sidecarTrackNumberWinsOverPlaylist() async throws {
        // Sidecar — деднамеренная правка с Мака, побеждает порядок плейлиста.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("track.flac"))
        try writePlaylist("track.flac\n", into: sub) // m3u-позиция = 1
        try writeSidecar("""
        {"version":1,"tracks":{"track.flac":{"trackNumber":9}}}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.first?.trackNumber == 9)
    }

    @Test func m3uFileNotScannedAsAudio() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("track.flac"))
        try writePlaylist("track.flac\n", into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.url.lastPathComponent == "track.flac")
    }

    @Test func sidecarLeavesUnmentionedTracksUntouched() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("02.flac"))
        // sidecar упоминает только 01.flac
        try writeSidecar("""
        {"version":1,"tracks":{"01.flac":{"title":"Изменён"}}}
        """, into: sub)

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 2)
        let first = infos.first { $0.url.lastPathComponent == "01.flac" }
        let second = infos.first { $0.url.lastPathComponent == "02.flac" }
        #expect(first?.title == "Изменён")
        // 02.flac не упомянут: album из имени папки (поведение этапа 2),
        // title — фоллбэк к имени файла без расширения ("02").
        #expect(second?.album == "Альбом")
        #expect(second?.title == "02")
    }
}
