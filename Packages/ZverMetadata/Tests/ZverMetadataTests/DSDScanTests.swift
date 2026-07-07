import Testing
import Foundation
@testable import ZverMetadata

@Suite struct DSDScanTests {
    // MARK: - Синтетический .dsf

    /// Пишет валидный минимальный DSF (заголовок `DSD `+`fmt `+`data`) с указанными
    /// параметрами. Данные — нули (для разбора заголовка и скана этого достаточно;
    /// декодирование в PCM делает ffmpeg на Маке, а не эти тесты).
    private static func writeDSF(to url: URL,
                                 sampleRate: UInt32 = 2_822_400,
                                 channels: UInt32 = 2,
                                 sampleCount: UInt64 = 2_822_400) throws {
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * $0)) & 0xFF) } }

        // Немного реальных данных, чтобы файл был «настоящим», но небольшим.
        let blockSize: UInt32 = 4096
        let dataBytes = Int(channels) * Int(blockSize)   // один блок на канал
        let dataChunkSize = UInt64(12 + dataBytes)

        var bytes: [UInt8] = []
        // DSD chunk
        bytes += Array("DSD ".utf8); bytes += u64(28)
        // полный размер посчитаем после
        let totalSizePos = bytes.count; bytes += u64(0); bytes += u64(0) // metadata ptr = 0
        // fmt chunk
        bytes += Array("fmt ".utf8); bytes += u64(52)
        bytes += u32(1)          // версия формата
        bytes += u32(0)          // id формата: DSD raw
        bytes += u32(2)          // тип каналов: стерео
        bytes += u32(channels)   // число каналов
        bytes += u32(sampleRate) // частота
        bytes += u32(1)          // бит на сэмпл
        bytes += u64(sampleCount)
        bytes += u32(blockSize)
        bytes += u32(0)          // reserved
        // data chunk
        bytes += Array("data".utf8); bytes += u64(dataChunkSize)
        bytes += [UInt8](repeating: 0, count: dataBytes)

        // впишем полный размер файла в DSD-чанк
        let total = UInt64(bytes.count)
        for (i, b) in u64(total).enumerated() { bytes[totalSizePos + i] = b }

        try Data(bytes).write(to: url)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Разбор заголовка

    @Test func parsesDSFHeaderFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dsf")
        try Self.writeDSF(to: url, sampleRate: 2_822_400, channels: 2, sampleCount: 5_644_800)
        let header = try DSFHeader.parse(url: url)
        #expect(header.sampleRate == 2_822_400)
        #expect(header.channels == 2)
        #expect(header.sampleCount == 5_644_800)
        #expect(header.duration == 2.0)          // 5 644 800 / 2 822 400
        #expect(header.dsdMultiple == 64)        // DSD64
    }

    @Test func rejectsShortAndBadMagic() throws {
        #expect(throws: DSFHeader.ParseError.tooShort) {
            try DSFHeader.parse(headerBytes: [UInt8](repeating: 0, count: 40))
        }
        var bytes = [UInt8](repeating: 0, count: 80)
        bytes.replaceSubrange(0..<4, with: Array("RIFF".utf8))
        #expect(throws: DSFHeader.ParseError.badMagic) {
            try DSFHeader.parse(headerBytes: bytes)
        }
    }

    // MARK: - Разбор имени файла

    @Test func parsesTrackNumberAndTitleFromFilename() {
        #expect(MetadataReader.parseTrackFilename("01 - Птица").number == 1)
        #expect(MetadataReader.parseTrackFilename("01 - Птица").title == "Птица")
        #expect(MetadataReader.parseTrackFilename("08 - С Днём Рождения").title == "С Днём Рождения")
        #expect(MetadataReader.parseTrackFilename("12. Foo").number == 12)
        #expect(MetadataReader.parseTrackFilename("12. Foo").title == "Foo")
        // Без ведущего номера — весь stem как название.
        #expect(MetadataReader.parseTrackFilename("Птица").number == nil)
        #expect(MetadataReader.parseTrackFilename("Птица").title == "Птица")
        // Только номер — не теряем название (фоллбэк на stem).
        #expect(MetadataReader.parseTrackFilename("01").title == "01")
    }

    // MARK: - Скан папки DSD

    @Test func scansDSFAlbumAsDSDTracks() async throws {
        let root = try makeFolder("Ночные Снайперы - Рубеж")
        try Self.writeDSF(to: root.appendingPathComponent("01 - Птица.dsf"),
                          sampleCount: 2_822_400)                // 1 c
        try Self.writeDSF(to: root.appendingPathComponent("02 - Дорога.dsf"),
                          sampleCount: 5_644_800)                // 2 c

        let infos = try await LibraryScanner.scan(directory: root.deletingLastPathComponent())
        #expect(infos.count == 2)
        #expect(infos.allSatisfy { $0.isDSD })
        #expect(infos.allSatisfy { $0.sampleRate == 2_822_400 })
        #expect(infos.allSatisfy { $0.bitDepth == nil })

        let sorted = infos.sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        #expect(sorted.map(\.trackNumber) == [1, 2])
        #expect(sorted.map(\.title) == ["Птица", "Дорога"])
        #expect(sorted[0].duration == 1.0)
        #expect(sorted[1].duration == 2.0)
        // Обычные (не-cue) треки: без cue-офсетов.
        #expect(sorted.allSatisfy { $0.startFrame == nil && $0.cueIndex == nil })
    }
}
