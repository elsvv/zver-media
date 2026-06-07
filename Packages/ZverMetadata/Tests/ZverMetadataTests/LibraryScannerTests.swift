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
