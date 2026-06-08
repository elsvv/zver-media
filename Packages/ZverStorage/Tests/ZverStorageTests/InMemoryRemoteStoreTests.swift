import Testing
import Foundation
import ZverTransport
@testable import ZverStorage

@Suite struct InMemoryRemoteStoreTests {
    /// Записывает временный файл с заданным содержимым, возвращает URL.
    /// Удаление — забота вызывающего (в тестах временная директория ОС подчищается).
    private func tempFile(_ content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-store-\(UUID().uuidString).bin")
        try content.write(to: url)
        return url
    }

    // MARK: - upload + exists

    @Test func uploadThenExistsReturnsShaAndSize() async throws {
        let store = InMemoryRemoteStore()
        let content = Data("hello cloud".utf8)
        let url = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        let uploaded = try await store.upload(localFile: url, to: "library/a/track.flac") { _ in }
        #expect(uploaded.size == Int64(content.count))
        #expect(uploaded.sha256 == Sha256.hash(content))
        #expect(uploaded.path == "library/a/track.flac")
        #expect(uploaded.name == "track.flac")
        #expect(uploaded.isDir == false)

        let found = try await store.exists(path: "library/a/track.flac")
        #expect(found != nil)
        #expect(found?.sha256 == Sha256.hash(content))
        #expect(found?.size == Int64(content.count))
    }

    @Test func existsOfMissingPathReturnsNil() async throws {
        let store = InMemoryRemoteStore()
        let found = try await store.exists(path: "library/nope.flac")
        #expect(found == nil)
    }

    @Test func uploadReportsProgressMonotonicallyUpToSize() async throws {
        let store = InMemoryRemoteStore()
        let content = Data((0..<10_000).map { UInt8($0 & 0xFF) })
        let url = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: url) }

        // Прогресс приходит с произвольной очереди (@Sendable) — собираем под локом.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int64] = []
            func append(_ v: Int64) { lock.lock(); values.append(v); lock.unlock() }
            var snapshot: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let box = Box()
        _ = try await store.upload(localFile: url, to: "p") { box.append($0) }

        let progress = box.snapshot
        #expect(!progress.isEmpty)
        #expect(progress.last == Int64(content.count))
        // монотонно неубывающий
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
    }

    // MARK: - download

    @Test func downloadReturnsSameBytes() async throws {
        let store = InMemoryRemoteStore()
        let content = Data("the quick brown fox".utf8)
        let src = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await store.upload(localFile: src, to: "library/a/t.flac") { _ in }

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-dl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dst) }

        let res = try await store.download(path: "library/a/t.flac", to: dst, resumeFrom: 0) { _ in }
        let readBack = try Data(contentsOf: dst)
        #expect(readBack == content)
        #expect(res.sha256 == Sha256.hash(content))
        #expect(res.size == Int64(content.count))
    }

    @Test func downloadResumeFromAppendsTailToExistingPrefix() async throws {
        let store = InMemoryRemoteStore()
        let content = Data("0123456789ABCDEF".utf8)
        let src = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await store.upload(localFile: src, to: "p") { _ in }

        // Готовим частично скачанный файл — первые 6 байт уже на диске.
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-dl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dst) }
        try content.prefix(6).write(to: dst)

        _ = try await store.download(path: "p", to: dst, resumeFrom: 6) { _ in }
        let readBack = try Data(contentsOf: dst)
        #expect(readBack == content)
    }

    @Test func downloadMissingPathThrowsNotFound() async throws {
        let store = InMemoryRemoteStore()
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-dl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dst) }

        await #expect(throws: RemoteError.self) {
            _ = try await store.download(path: "missing", to: dst, resumeFrom: 0) { _ in }
        }
    }

    // MARK: - delete

    @Test func deleteRemovesResource() async throws {
        let store = InMemoryRemoteStore()
        let url = try tempFile(Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await store.upload(localFile: url, to: "p") { _ in }
        #expect(try await store.exists(path: "p") != nil)

        try await store.delete(path: "p")
        #expect(try await store.exists(path: "p") == nil)
    }

    @Test func deleteMissingIsNoOp() async throws {
        let store = InMemoryRemoteStore()
        // Не должно бросать.
        try await store.delete(path: "never-existed")
    }

    // MARK: - list

    @Test func listReturnsResourcesUnderFolder() async throws {
        let store = InMemoryRemoteStore()
        let a = try tempFile(Data("a".utf8))
        let b = try tempFile(Data("bb".utf8))
        let other = try tempFile(Data("ccc".utf8))
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
            try? FileManager.default.removeItem(at: other)
        }
        _ = try await store.upload(localFile: a, to: "library/album/1.flac") { _ in }
        _ = try await store.upload(localFile: b, to: "library/album/2.flac") { _ in }
        _ = try await store.upload(localFile: other, to: "library/elsewhere/3.flac") { _ in }

        let listed = try await store.list(folder: "library/album")
        let paths = Set(listed.map(\.path))
        #expect(paths == ["library/album/1.flac", "library/album/2.flac"])
    }

    @Test func listEmptyFolderReturnsEmpty() async throws {
        let store = InMemoryRemoteStore()
        let listed = try await store.list(folder: "library/empty")
        #expect(listed.isEmpty)
    }

    // MARK: - ensureFolder

    @Test func ensureFolderIsIdempotent() async throws {
        let store = InMemoryRemoteStore()
        // Повтор не бросает.
        try await store.ensureFolder(path: "library/album")
        try await store.ensureFolder(path: "library/album")
    }

    // MARK: - usable as RemoteStore (абстракция)

    @Test func conformsToRemoteStoreProtocol() async throws {
        let store: any RemoteStore = InMemoryRemoteStore()
        let url = try tempFile(Data("z".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let r = try await store.upload(localFile: url, to: "p") { _ in }
        #expect(r.size == 1)
    }
}
