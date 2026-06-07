import Testing
import Foundation
@testable import ZverTransport

@Suite struct Sha256Tests {
    // Известные векторы NIST для SHA-256.
    @Test func emptyStringVector() {
        let hash = Sha256.hash(Data())
        #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func abcVector() {
        let hash = Sha256.hash(Data("abc".utf8))
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func hexIsLowercase() {
        let hash = Sha256.hash(Data("Zver".utf8))
        #expect(hash == hash.lowercased())
        #expect(hash.count == 64)
    }

    @Test func dataAndFileMatchOnSameContent() throws {
        let content = Data("the quick brown fox jumps over the lazy dog".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-sha-\(UUID().uuidString).bin")
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromData = Sha256.hash(content)
        let fromFile = try Sha256.hash(fileURL: url)
        #expect(fromData == fromFile)
    }

    @Test func emptyFileMatchesEmptyData() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-sha-empty-\(UUID().uuidString).bin")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromFile = try Sha256.hash(fileURL: url)
        #expect(fromFile == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // Файл больше размера чанка (1 МБ) — проверяем потоковое хеширование по чанкам.
    @Test func largeFileExceedingChunkSizeHashesCorrectly() throws {
        // 3 МБ + хвост, чтобы пересечь несколько границ чанков и оставить
        // неполный последний чанк.
        var content = Data()
        let block = Data((0..<1024).map { UInt8($0 & 0xFF) })
        for _ in 0..<(3 * 1024 + 7) {
            content.append(block)
        }
        #expect(content.count > 1 * 1024 * 1024)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-sha-large-\(UUID().uuidString).bin")
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fromData = Sha256.hash(content)
        let fromFile = try Sha256.hash(fileURL: url)
        #expect(fromData == fromFile)
    }

    @Test func missingFileThrows() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-sha-nonexistent-\(UUID().uuidString).bin")
        #expect(throws: (any Error).self) {
            _ = try Sha256.hash(fileURL: url)
        }
    }
}
