import Testing
import Foundation
@testable import ZverMetadata

@Suite struct CueScanTests {
    // ui_smoke.flac — 44100 Гц, ~8 c: удобный контейнер образа.
    private static let container = "ui_smoke.flac"
    private static let sampleRate: Int64 = 44100

    private func makeAlbum(named folder: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let root = tmp.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func flacPlusCueExpandsToTracksWithSampleOffsets() async throws {
        let root = try makeAlbum(named: "Portishead - Dummy (Japan)")
        let flac = root.appendingPathComponent("Portishead - Dummy.flac")
        try FileManager.default.copyItem(at: fixture(Self.container), to: flac)
        // Один FILE, 3 трека: старт 0 / 2 c / 5 c.
        try Data("""
        PERFORMER "Portishead"
        TITLE "Dummy"
        FILE "Portishead - Dummy.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Mysterons"
            PERFORMER "Portishead"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Sour Times"
            PERFORMER "Portishead"
            INDEX 01 00:02:00
          TRACK 03 AUDIO
            TITLE "Strangers"
            PERFORMER "Portishead"
            INDEX 01 00:05:00
        """.utf8).write(to: root.appendingPathComponent("Portishead - Dummy.cue"))

        let tmp = root.deletingLastPathComponent()
        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 3)

        // Все N делят ОДИН контейнер (url = .flac).
        #expect(Set(infos.map(\.url.path)).count == 1)
        #expect(infos.allSatisfy { $0.url.lastPathComponent == "Portishead - Dummy.flac" })

        let sorted = infos.sorted { ($0.cueIndex ?? 0) < ($1.cueIndex ?? 0) }
        #expect(sorted.map(\.cueIndex) == [1, 2, 3])
        #expect(sorted.map(\.trackNumber) == [1, 2, 3])
        #expect(sorted.map(\.title) == ["Mysterons", "Sour Times", "Strangers"])
        #expect(sorted.allSatisfy { $0.artist == "Portishead" })

        // Границы в сэмплах (44100/75 точно, поэтому целые).
        let sr = Self.sampleRate
        let expectedStarts: [Int64?] = [0, 2 * sr, 5 * sr]
        #expect(sorted.map(\.startFrame) == expectedStarts)
        // frameCount = разница стартов; последний — nil (sentinel «до EOF»: плеер
        // доиграет до реальной длины файла, а не до оценочной длительности).
        #expect(sorted[0].frameCount == 2 * sr)
        #expect(sorted[1].frameCount == 3 * sr)
        #expect(sorted[2].frameCount == nil)
        #expect(sorted[2].startFrame == 5 * sr)

        // Per-track duration (не полный контейнер): не-последние = count/sr точно,
        // последний — оценка «контейнер минус старт» (> 0 для ~8 c контейнера).
        #expect(sorted[0].duration == 2.0)
        #expect(sorted[1].duration == 3.0)
        #expect(sorted[2].duration > 0)
    }

    @Test func multiFileCueExpandsEachFileIntoItsTracks() async throws {
        // Multi-file cue (винил): один `.cue` ссылается на несколько `.flac` (стороны),
        // каждый FILE — свои треки. Каждая сторона раскрывается в свои треки; офсеты
        // ОТНОСИТЕЛЬНЫ началу своего файла; нумерация сквозная; последний трек стороны
        // — до её EOF. Имя `.cue` НЕ совпадает с именами `.flac` — матч по FILE.
        let root = try makeAlbum(named: "Vinyl")
        let fm = FileManager.default
        try fm.copyItem(at: fixture(Self.container), to: root.appendingPathComponent("album - side 1.flac"))
        try fm.copyItem(at: fixture(Self.container), to: root.appendingPathComponent("album - side 2.flac"))
        try Data("""
        PERFORMER "Artist"
        TITLE "Vinyl"
        FILE "album - side 1.flac" WAVE
          TRACK 01 AUDIO
            TITLE "A1"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "A2"
            INDEX 01 00:03:00
        FILE "album - side 2.flac" WAVE
          TRACK 03 AUDIO
            TITLE "B1"
            INDEX 01 00:00:00
          TRACK 04 AUDIO
            TITLE "B2"
            INDEX 01 00:04:00
        """.utf8).write(to: root.appendingPathComponent("Vinyl.cue"))

        let infos = try await LibraryScanner.scan(directory: root.deletingLastPathComponent())
        #expect(infos.count == 4)

        let sorted = infos.sorted { ($0.cueIndex ?? 0) < ($1.cueIndex ?? 0) }
        #expect(sorted.map(\.cueIndex) == [1, 2, 3, 4])          // сквозная нумерация
        #expect(sorted.map(\.trackNumber) == [1, 2, 3, 4])
        #expect(sorted.map(\.title) == ["A1", "A2", "B1", "B2"])
        // Каждая сторона — свой контейнер:
        #expect(sorted[0].url.lastPathComponent == "album - side 1.flac")
        #expect(sorted[1].url.lastPathComponent == "album - side 1.flac")
        #expect(sorted[2].url.lastPathComponent == "album - side 2.flac")
        #expect(sorted[3].url.lastPathComponent == "album - side 2.flac")
        // Офсеты ОТНОСИТЕЛЬНЫ началу своего файла (B1 = 0, НЕ длина стороны 1):
        let sr = Self.sampleRate
        #expect(sorted.map(\.startFrame) == [0, 3 * sr, 0, 4 * sr])
        // Последний трек КАЖДОЙ стороны — до её EOF (frameCount nil):
        #expect(sorted[0].frameCount == 3 * sr)   // A1
        #expect(sorted[1].frameCount == nil)      // A2 (последний стороны 1)
        #expect(sorted[2].frameCount == 4 * sr)   // B1
        #expect(sorted[3].frameCount == nil)      // B2 (последний стороны 2)
    }

    @Test func multiFileCueIsNotExpanded() async throws {
        // Одноимённый cue, но с несколькими FILE (не образ) — не раскрываем:
        // контейнер остаётся одним обычным треком без офсетов.
        let root = try makeAlbum(named: "Multi")
        let flac = root.appendingPathComponent("album.flac")
        try FileManager.default.copyItem(at: fixture(Self.container), to: flac)
        try Data("""
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "One"
            INDEX 01 00:00:00
        FILE "second.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Two"
            INDEX 01 00:00:00
        """.utf8).write(to: root.appendingPathComponent("album.cue"))

        let infos = try await LibraryScanner.scan(directory: root.deletingLastPathComponent())
        #expect(infos.count == 1)
        #expect(infos.first?.cueIndex == nil)
        #expect(infos.first?.startFrame == nil)
        #expect(infos.first?.frameCount == nil)
    }

    @Test func flacWithoutSiblingCueIsNormalTrack() async throws {
        // Нет одноимённого cue (имя не совпадает) — обычный трек, без офсетов.
        let root = try makeAlbum(named: "Normal")
        try FileManager.default.copyItem(
            at: fixture(Self.container), to: root.appendingPathComponent("track.flac"))
        try Data("""
        FILE "other.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 00:02:00
        """.utf8).write(to: root.appendingPathComponent("other.cue"))

        let infos = try await LibraryScanner.scan(directory: root.deletingLastPathComponent())
        #expect(infos.count == 1)
        #expect(infos.first?.startFrame == nil)
        #expect(infos.first?.cueIndex == nil)
    }

    @Test func normalAlbumUnaffectedByCueSupport() async throws {
        // Регресс: обычный многофайловый альбом без cue не меняется.
        let root = try makeAlbum(named: "Plain")
        let fm = FileManager.default
        try fm.copyItem(at: fixture("tagged_16_44.flac"), to: root.appendingPathComponent("01.flac"))
        try fm.copyItem(at: fixture("notags.flac"), to: root.appendingPathComponent("02.flac"))

        let infos = try await LibraryScanner.scan(directory: root.deletingLastPathComponent())
        #expect(infos.count == 2)
        #expect(infos.allSatisfy { $0.startFrame == nil && $0.cueIndex == nil })
    }

    // MARK: - Shift-JIS

    @Test func readTextDecodesShiftJIS() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cue")
        let text = "TITLE \"ミステロンズ\"\nPERFORMER \"ポーティスヘッド\"\n"
        try #require(text.data(using: .shiftJIS)).write(to: tmp)

        // UTF-8 на этих байтах честно падает → берётся Shift-JIS.
        #expect(String(data: try Data(contentsOf: tmp), encoding: .utf8) == nil)
        #expect(LibraryScanner.readText(tmp) == text)
    }

    @Test func readTextDecodesUTF8() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cue")
        let text = "TITLE \"Тест\"\n"
        try Data(text.utf8).write(to: tmp)
        #expect(LibraryScanner.readText(tmp) == text)
    }

    @Test func readTextDecodesWesternLatin1NotAsJapanese() throws {
        // Западный cue в Latin-1: `ö` (0xF6) — валидный ведущий байт Shift-JIS, `r`
        // (0x72) — валидный хвостовой, поэтому жадный SJIS декодировал бы `ör` в кандзи.
        // Одиночные кандзи (нет серии CJK) → SJIS отвергается, имена читаются корректно.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".cue")
        let text = "PERFORMER \"Motörhead\"\nTITLE \"Björk\"\n"
        try #require(text.data(using: .isoLatin1)).write(to: tmp)

        #expect(String(data: try Data(contentsOf: tmp), encoding: .utf8) == nil) // UTF-8 падает
        let decoded = try #require(LibraryScanner.readText(tmp))
        #expect(decoded.contains("Motörhead"))
        #expect(decoded.contains("Björk"))
    }

    @Test func scanDecodesShiftJISCueTitles() async throws {
        let root = try makeAlbum(named: "日本盤")
        let flac = root.appendingPathComponent("album.flac")
        try FileManager.default.copyItem(at: fixture(Self.container), to: flac)
        let cueText = """
        FILE "album.flac" WAVE
          TRACK 01 AUDIO
            TITLE "一曲目"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "二曲目"
            INDEX 01 00:03:00
        """
        try #require(cueText.data(using: .shiftJIS))
            .write(to: root.appendingPathComponent("album.cue"))

        let infos = try await LibraryScanner.scan(directory: root.deletingLastPathComponent())
        #expect(infos.count == 2)
        let sorted = infos.sorted { ($0.cueIndex ?? 0) < ($1.cueIndex ?? 0) }
        #expect(sorted.map(\.title) == ["一曲目", "二曲目"])
    }
}
