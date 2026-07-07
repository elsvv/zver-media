import Testing
import Foundation
@testable import ZverImport

/// Раскладка тела ответа Internet Archive на диск — самая тонкая часть докачки по `Range`:
/// именно она делает частичный файл переживающим обрыв соединения. Проверяем три пути
/// диспозиции по HTTP-статусу на временных файлах (без сети): 206 (дописать хвост к
/// префиксу), 200 (перезаписать с нуля, даже если Range был проигнорирован), не-2xx
/// (не тронуть частичный файл и бросить). Плюс `partialSize` — позицию докачки.
@Suite struct ArchiveFileSinkTests {

    /// Уникальная песочница на тест в системном tmp.
    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveFileSinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - partialSize (позиция докачки)

    @Test func partialSizeIsZeroForMissingFile() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ArchiveFileSink.partialSize(dir.appendingPathComponent("nope.flac")) == 0)
    }

    @Test func partialSizeReportsExistingPrefixLength() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("part.flac")
        try Data(repeating: 0xAB, count: 4096).write(to: url)
        #expect(ArchiveFileSink.partialSize(url) == 4096)
    }

    // MARK: - 200: полный ответ

    @Test func status200WritesFreshFile() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("track.flac")
        let body = Data("FLAC-full-body".utf8)

        let sink = ArchiveFileSink(destination: url)
        try sink.open(status: 200, resumeFrom: 0)
        try sink.write(body)
        sink.close()

        #expect(try Data(contentsOf: url) == body)
        #expect(sink.bytesOnDisk == Int64(body.count))
    }

    @Test func status200OverwritesStalePartialFromScratch() throws {
        // Range был запрошен (resumeFrom > 0), но сервер ответил 200 (проигнорировал Range) —
        // старый префикс НЕ конкатенируем, а перезаписываем целиком, иначе файл битый.
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("track.flac")
        let stale = Data(repeating: 0x00, count: 1000)
        try stale.write(to: url)
        let body = Data("full-fresh-body".utf8)

        let sink = ArchiveFileSink(destination: url)
        try sink.open(status: 200, resumeFrom: Int64(stale.count))
        try sink.write(body)
        sink.close()

        // Файл — ровно тело ответа, без остатков старого префикса.
        #expect(try Data(contentsOf: url) == body)
        #expect(sink.bytesOnDisk == Int64(body.count))
    }

    @Test func status200CreatesMissingParentDirectory() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Приёмник в несуществующей подпапке — open создаёт её.
        let url = dir.appendingPathComponent("sub/dir/track.flac")
        let body = Data("body".utf8)

        let sink = ArchiveFileSink(destination: url)
        try sink.open(status: 200, resumeFrom: 0)
        try sink.write(body)
        sink.close()

        #expect(try Data(contentsOf: url) == body)
    }

    // MARK: - 206: докачка хвоста к префиксу

    @Test func status206AppendsTailToExistingPrefix() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("track.flac")
        let prefix = Data("already-on-disk-".utf8)
        try prefix.write(to: url)
        let tail = Data("downloaded-tail".utf8)

        let sink = ArchiveFileSink(destination: url)
        try sink.open(status: 206, resumeFrom: Int64(prefix.count))
        // После open доля учитывает уже лежащий префикс.
        #expect(sink.bytesOnDisk == Int64(prefix.count))
        try sink.write(tail)
        sink.close()

        #expect(try Data(contentsOf: url) == prefix + tail)
        #expect(sink.bytesOnDisk == Int64(prefix.count + tail.count))
    }

    @Test func status206WithoutExistingPrefixWritesFromScratch() throws {
        // 206, но файла на диске нет (защита от рассинхрона) — пишем тело как есть.
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("track.flac")
        let body = Data("body-206-no-prefix".utf8)

        let sink = ArchiveFileSink(destination: url)
        try sink.open(status: 206, resumeFrom: 500)   // resumeFrom>0, но файла нет
        try sink.write(body)
        sink.close()

        #expect(try Data(contentsOf: url) == body)
        #expect(sink.bytesOnDisk == Int64(body.count))
    }

    // MARK: - не-2xx: частичный файл не тронут

    @Test func nonSuccessStatusThrowsAndKeepsPartialUntouched() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("track.flac")
        let prefix = Data(repeating: 0x7F, count: 2048)
        try prefix.write(to: url)

        let sink = ArchiveFileSink(destination: url)
        #expect(throws: ArchiveFileSink.DownloadError.http(503)) {
            try sink.open(status: 503, resumeFrom: Int64(prefix.count))
        }
        // Частичный префикс на диске переживает транзиентный сбой — докачка продолжится.
        #expect(try Data(contentsOf: url) == prefix)
        #expect(ArchiveFileSink.partialSize(url) == Int64(prefix.count))
    }

    @Test func notFoundStatusThrowsHttp404() throws {
        let dir = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("track.flac")

        let sink = ArchiveFileSink(destination: url)
        #expect(throws: ArchiveFileSink.DownloadError.http(404)) {
            try sink.open(status: 404, resumeFrom: 0)
        }
    }
}
