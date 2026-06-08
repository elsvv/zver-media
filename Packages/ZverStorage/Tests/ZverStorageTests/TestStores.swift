import Foundation
@testable import ZverStorage

/// Счётчик пика одновременно активных upload-ов и общего числа аплоадов.
/// Актор — потокобезопасен без ручных локов.
actor ConcurrencyProbe {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var uploadCount = 0

    func enter() {
        active += 1
        peak = max(peak, active)
        uploadCount += 1
    }

    func leave() {
        active -= 1
    }
}

/// Декоратор ``RemoteStore``, замеряющий конкурентность аплоадов через ``ConcurrencyProbe``.
///
/// Вставляет небольшую асинхронную паузу (`Task.yield` несколько раз) между `enter` и
/// `leave`, чтобы дать планировщику шанс запустить параллельные задачи и тем выявить
/// нарушение лимита `maxConcurrent`.
final class ProbingStore: RemoteStore, @unchecked Sendable {
    private let inner: InMemoryRemoteStore
    private let probe: ConcurrencyProbe

    init(inner: InMemoryRemoteStore, probe: ConcurrencyProbe) {
        self.inner = inner
        self.probe = probe
    }

    func exists(path: String) async throws -> RemoteResource? {
        try await inner.exists(path: path)
    }

    func list(folder: String) async throws -> [RemoteResource] {
        try await inner.list(folder: folder)
    }

    func ensureFolder(path: String) async throws {
        try await inner.ensureFolder(path: path)
    }

    func upload(
        localFile: URL,
        to path: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        await probe.enter()
        // Уступаем планировщику, чтобы параллельные задачи могли пересечься во времени.
        for _ in 0..<8 { await Task.yield() }
        let result: RemoteResource
        do {
            result = try await inner.upload(localFile: localFile, to: path, progress: progress)
        } catch {
            await probe.leave()
            throw error
        }
        await probe.leave()
        return result
    }

    func download(
        path: String,
        to localFile: URL,
        resumeFrom: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        try await inner.download(path: path, to: localFile, resumeFrom: resumeFrom, progress: progress)
    }

    func delete(path: String) async throws {
        try await inner.delete(path: path)
    }
}

/// Декоратор ``RemoteStore``, бросающий заранее заданную последовательность ошибок на
/// `upload`/`download`, прежде чем делегировать реальному `inner`.
///
/// Для каждого вызова `upload`/`download` берёт следующую ошибку из `failures` (FIFO);
/// когда список исчерпан — выполняет настоящую операцию. Так моделируем «N сбоев,
/// затем успех» для проверки ретраев очереди. Потокобезопасен через `NSLock`.
final class FlakyStore: RemoteStore, @unchecked Sendable {
    private let inner: InMemoryRemoteStore
    private let lock = NSLock()
    private var failures: [RemoteError]

    init(inner: InMemoryRemoteStore, failures: [RemoteError]) {
        self.inner = inner
        self.failures = failures
    }

    private func nextFailure() -> RemoteError? {
        lock.lock(); defer { lock.unlock() }
        guard !failures.isEmpty else { return nil }
        return failures.removeFirst()
    }

    func exists(path: String) async throws -> RemoteResource? {
        try await inner.exists(path: path)
    }

    func list(folder: String) async throws -> [RemoteResource] {
        try await inner.list(folder: folder)
    }

    func ensureFolder(path: String) async throws {
        try await inner.ensureFolder(path: path)
    }

    func upload(
        localFile: URL,
        to path: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        if let failure = nextFailure() { throw failure }
        return try await inner.upload(localFile: localFile, to: path, progress: progress)
    }

    func download(
        path: String,
        to localFile: URL,
        resumeFrom: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        if let failure = nextFailure() { throw failure }
        return try await inner.download(path: path, to: localFile, resumeFrom: resumeFrom, progress: progress)
    }

    func delete(path: String) async throws {
        try await inner.delete(path: path)
    }
}
