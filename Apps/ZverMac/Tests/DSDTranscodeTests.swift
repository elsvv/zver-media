import XCTest
import AVFoundation
@testable import ZverMac

/// Интеграционные тесты конвертации DSD → FLAC на Маке (используют реальный
/// `ffmpeg`). Синтетический `.dsf` (валидный заголовок Sony DSF + нулевые данные)
/// прогоняется через транскодер/стейджинг; проверяем формат итогового FLAC.
final class DSDTranscodeTests: XCTestCase {

    // MARK: - Синтетический .dsf

    /// Пишет валидный минимальный DSF (заголовок + N блоков нулевых данных).
    private func writeDSF(to url: URL,
                          sampleRate: UInt32 = 2_822_400,
                          channels: UInt32 = 2,
                          blocks: Int = 20) {
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }

        let blockSize: UInt32 = 4096
        let dataBytes = Int(channels) * Int(blockSize) * blocks
        let sampleCount = UInt64(blocks) * UInt64(blockSize) * 8   // 1-бит сэмплов/канал

        var b: [UInt8] = []
        b += Array("DSD ".utf8); b += u64(28)
        let totalPos = b.count; b += u64(0); b += u64(0)           // размер файла впишем позже; metadata ptr = 0
        b += Array("fmt ".utf8); b += u64(52)
        b += u32(1); b += u32(0); b += u32(2); b += u32(channels)
        b += u32(sampleRate); b += u32(1); b += u64(sampleCount)
        b += u32(blockSize); b += u32(0)
        b += Array("data".utf8); b += u64(UInt64(12 + dataBytes))
        b += [UInt8](repeating: 0, count: dataBytes)
        for (i, byte) in u64(UInt64(b.count)).enumerated() { b[totalPos + i] = byte }

        try? Data(b).write(to: url)
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsdtest-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - ffmpeg найден

    func testFFmpegIsLocatable() throws {
        // На машине разработки ffmpeg установлен (brew) — локатор его находит.
        let ffmpeg = FFmpegLocator.find()
        XCTAssertNotNil(ffmpeg, "ffmpeg не найден — установите: brew install ffmpeg")
        if let ffmpeg {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ffmpeg.path))
        }
    }

    // MARK: - Транскодер даёт валидный FLAC нужной частоты

    func testTranscodeProducesFLACAtTargetRate() throws {
        guard let ffmpeg = FFmpegLocator.find() else {
            throw XCTSkip("ffmpeg не установлен")
        }
        let dir = tempDir()
        let input = dir.appendingPathComponent("in.dsf")
        let output = dir.appendingPathComponent("out.flac")
        writeDSF(to: input, blocks: 40)

        try DSDTranscoder.transcode(dsf: input, to: output, quality: .hi, ffmpeg: ffmpeg)

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let flac = try AVAudioFile(forReading: output)
        XCTAssertEqual(flac.fileFormat.sampleRate, 176_400)   // .hi
        XCTAssertGreaterThan(flac.length, 0)

        // .standard → 88.2к
        let output2 = dir.appendingPathComponent("out2.flac")
        try DSDTranscoder.transcode(dsf: input, to: output2, quality: .standard, ffmpeg: ffmpeg)
        let flac2 = try AVAudioFile(forReading: output2)
        XCTAssertEqual(flac2.fileFormat.sampleRate, 88_200)
    }

    // MARK: - Staging материализует DSD-альбом в FLAC

    func testMaterializeRewritesDSDAlbumToStagingFLAC() throws {
        guard let ffmpeg = FFmpegLocator.find() else {
            throw XCTSkip("ffmpeg не установлен")
        }
        let source = tempDir()
        // Два DSD-трека + обложка в исходной папке.
        writeDSF(to: source.appendingPathComponent("01 - Птица.dsf"), blocks: 20)
        writeDSF(to: source.appendingPathComponent("02 - Дорога.dsf"), blocks: 30)
        let cover = source.appendingPathComponent("folder.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: cover)   // минимальный «jpeg»

        func track(_ name: String) -> ManifestBuilder.DraftSnapshot.TrackSnapshot {
            .init(fileURL: source.appendingPathComponent(name),
                  fileName: name, relativePath: name, fileExtension: "dsf",
                  title: name, artist: "A", album: "Alb", trackNumber: nil,
                  discNumber: nil, year: nil, duration: 0,
                  sampleRate: 2_822_400, bitDepth: nil)
        }
        let snapshot = ManifestBuilder.DraftSnapshot(
            albumId: "a-alb", title: "Alb", artist: "A", year: nil,
            sourceFolder: source, artworkFileName: "folder.jpg",
            playlistFileName: nil, extraFileNames: [],
            tracks: [track("01 - Птица.dsf"), track("02 - Дорога.dsf")])

        XCTAssertTrue(DSDStaging.containsDSD(snapshot))
        let staged = try DSDStaging.materialize(snapshot, quality: .standard, ffmpeg: ffmpeg)

        // Источник переехал в staging (исходная папка не тронута).
        XCTAssertNotEqual(staged.sourceFolder, source)
        XCTAssertTrue(DSDStaging.isStaged(staged.sourceFolder))
        // Исходные .dsf на месте, ничего не перезаписано.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("01 - Птица.dsf").path))

        // Все треки стали FLAC, лежат в staging, реально существуют, нужной частоты.
        XCTAssertEqual(staged.tracks.count, 2)
        for t in staged.tracks {
            XCTAssertEqual(t.fileExtension, "flac")
            XCTAssertTrue(t.relativePath.hasSuffix(".flac"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: t.fileURL.path), "нет \(t.fileURL.lastPathComponent)")
            XCTAssertEqual(t.sampleRate, 88_200)
            XCTAssertEqual(t.bitDepth, 24)
            // Раздача читает sourceFolder + relativePath — путь должен сходиться.
            XCTAssertEqual(staged.sourceFolder.appendingPathComponent(t.relativePath).path, t.fileURL.path)
        }
        // Обложка скопирована в staging.
        XCTAssertEqual(staged.artworkFileName, "folder.jpg")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.sourceFolder.appendingPathComponent("folder.jpg").path))

        // Чистка удаляет staging, но не источник.
        DSDStaging.cleanup(staged.sourceFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.sourceFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - Не-DSD альбом проходит насквозь

    func testMaterializeLeavesNonDSDUnchanged() throws {
        let ffmpeg = FFmpegLocator.find() ?? URL(fileURLWithPath: "/usr/bin/true")
        let source = tempDir()
        let snapshot = ManifestBuilder.DraftSnapshot(
            albumId: "x", title: "X", artist: nil, year: nil,
            sourceFolder: source, artworkFileName: nil,
            playlistFileName: nil, extraFileNames: [],
            tracks: [.init(fileURL: source.appendingPathComponent("01.flac"),
                           fileName: "01.flac", relativePath: "01.flac", fileExtension: "flac",
                           title: "t", artist: nil, album: nil, trackNumber: 1,
                           discNumber: nil, year: nil, duration: 1, sampleRate: 44_100, bitDepth: 16)])
        XCTAssertFalse(DSDStaging.containsDSD(snapshot))
        let out = try DSDStaging.materialize(snapshot, quality: .hi, ffmpeg: ffmpeg)
        XCTAssertEqual(out.sourceFolder, source)                 // не переехал
        XCTAssertEqual(out.tracks.first?.fileExtension, "flac")
        XCTAssertEqual(out.tracks.first?.sampleRate, 44_100)     // не тронут
    }

    // MARK: - Коллизия имён (смешанный DSD+FLAC альбом)

    func testMaterializeDisambiguatesCollidingStems() throws {
        guard let ffmpeg = FFmpegLocator.find() else { throw XCTSkip("ffmpeg не установлен") }
        let source = tempDir()
        writeDSF(to: source.appendingPathComponent("Song.dsf"), blocks: 10)
        // Не-DSD трек с тем же стемом → выходной путь совпал бы с «Song.flac».
        try Data("fLaC".utf8).write(to: source.appendingPathComponent("Song.flac"))
        func t(_ name: String, _ ext: String) -> ManifestBuilder.DraftSnapshot.TrackSnapshot {
            .init(fileURL: source.appendingPathComponent(name), fileName: name, relativePath: name,
                  fileExtension: ext, title: name, artist: nil, album: nil, trackNumber: nil,
                  discNumber: nil, year: nil, duration: 0, sampleRate: 2_822_400, bitDepth: nil)
        }
        let snapshot = ManifestBuilder.DraftSnapshot(
            albumId: "collide", title: "C", artist: nil, year: nil, sourceFolder: source,
            artworkFileName: nil, playlistFileName: nil, extraFileNames: [],
            tracks: [t("Song.dsf", "dsf"), t("Song.flac", "flac")])

        let staged = try DSDStaging.materialize(snapshot, quality: .standard, ffmpeg: ffmpeg)
        let rels = staged.tracks.map(\.relativePath)
        XCTAssertEqual(Set(rels).count, 2, "пути должны быть уникальны, получили \(rels)")
        for track in staged.tracks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: track.fileURL.path))
            XCTAssertEqual(staged.sourceFolder.appendingPathComponent(track.relativePath).path, track.fileURL.path)
        }
        DSDStaging.cleanup(staged.sourceFolder)
    }

    // MARK: - Чистка staging безопасна

    func testCleanupGuardsNonStagedAndSweepClearsStaging() throws {
        // cleanup НЕ трогает папку вне staging (напр. настоящую папку музыки).
        let userFolder = tempDir()
        try Data([1, 2, 3]).write(to: userFolder.appendingPathComponent("keep.txt"))
        XCTAssertFalse(DSDStaging.isStaged(userFolder))
        DSDStaging.cleanup(userFolder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFolder.path),
                      "cleanup не должен удалять папку вне staging")

        // sweepAll сносит осиротевший staging.
        let root = try DSDStaging.stagingRoot()
        let junk = root.appendingPathComponent("orphan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data([1]).write(to: junk.appendingPathComponent("x.flac"))
        XCTAssertTrue(DSDStaging.isStaged(junk))
        DSDStaging.sweepAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: junk.path),
                       "sweepAll должен снести staging-сироту")
    }
}
