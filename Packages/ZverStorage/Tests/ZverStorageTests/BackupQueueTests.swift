import Testing
import Foundation
import ZverTransport
@testable import ZverStorage

/// Тесты планировщика передач ``BackupQueue`` на ``InMemoryRemoteStore`` +
/// ``FakeSleeper`` — без сети и без реального ожидания.
///
/// Проверяем: дренаж очереди по ≤`maxConcurrent` параллельно, успех с облачным sha,
/// сверка `expectedSha`, ретраи через ``RetryPolicy`` + ``Sleeper`` (backoff),
/// нерекаверабельный фейл без сна, дедуп по `id`, докачку скачивания с `resumeFrom`,
/// эмиссию событий состояния.
@Suite struct BackupQueueTests {

    // MARK: - хелперы

    /// Собирает события `(id, TransferState)` потокобезопасно.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, TransferState)] = []
        func record(_ id: String, _ state: TransferState) {
            lock.lock(); events.append((id, state)); lock.unlock()
        }
        var all: [(String, TransferState)] { lock.lock(); defer { lock.unlock() }; return events }
        func states(for id: String) -> [TransferState] {
            all.filter { $0.0 == id }.map { $0.1 }
        }
    }

    private func tempFile(_ content: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-q-\(UUID().uuidString).bin")
        try content.write(to: url)
        return url
    }

    private func backupItem(id: String, content: Data, path: String, expectedSha: String?) throws -> BackupItem {
        let url = try tempFile(content)
        return BackupItem(
            id: id,
            localFile: url,
            remotePath: path,
            expectedSha: expectedSha,
            fileSize: Int64(content.count)
        )
    }

    // MARK: - базовый успех

    @Test func uploadsItemAndEmitsDoneWithCloudSha() async throws {
        let store = InMemoryRemoteStore()
        let log = EventLog()
        let queue = BackupQueue(
            store: store,
            policy: RetryPolicy(),
            sleeper: FakeSleeper(),
            maxConcurrent: 2
        ) { id, state in log.record(id, state) }

        let content = Data("hello".utf8)
        let item = try backupItem(id: "t1", content: content, path: "library/a/t.flac", expectedSha: Sha256.hash(content))
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        // Файл лёг в облако.
        let inCloud = try await store.exists(path: "library/a/t.flac")
        #expect(inCloud?.sha256 == Sha256.hash(content))

        // Финальное событие — .done с облачным sha.
        let states = log.states(for: "t1")
        guard case let .done(resource) = states.last else {
            Issue.record("ожидался финальный .done, получено \(String(describing: states.last))")
            return
        }
        #expect(resource.sha256 == Sha256.hash(content))
    }

    @Test func emitsLifecycleEventsInOrder() async throws {
        let store = InMemoryRemoteStore()
        let log = EventLog()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let content = Data("abc".utf8)
        let item = try backupItem(id: "x", content: content, path: "p", expectedSha: Sha256.hash(content))
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        let states = log.states(for: "x")
        // Первая стадия — queued, последняя — done; между ними проходит transferring.
        #expect(states.first == .queued)
        #expect(states.contains { if case .transferring = $0 { return true } else { return false } })
        guard case .done = states.last else {
            Issue.record("ожидался финальный .done")
            return
        }
    }

    // MARK: - параллелизм ≤ maxConcurrent

    @Test func neverExceedsMaxConcurrent() async throws {
        // Стор, считающий пик одновременно активных upload-ов.
        let probe = ConcurrencyProbe()
        let store = ProbingStore(inner: InMemoryRemoteStore(), probe: probe)
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 2) { _, _ in }

        for i in 0..<8 {
            let content = Data("payload-\(i)".utf8)
            let item = try backupItem(id: "t\(i)", content: content, path: "library/a/\(i).flac", expectedSha: Sha256.hash(content))
            defer { try? FileManager.default.removeItem(at: item.localFile) }
            await queue.enqueueUpload(item)
        }
        await queue.run()

        let peak = await probe.peak
        #expect(peak <= 2)
        #expect(peak >= 1)
    }

    @Test func drainsAllQueuedItems() async throws {
        let store = InMemoryRemoteStore()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 2) { _, _ in }
        var urls: [URL] = []
        for i in 0..<5 {
            let content = Data("file-\(i)".utf8)
            let item = try backupItem(id: "t\(i)", content: content, path: "library/a/\(i).flac", expectedSha: Sha256.hash(content))
            urls.append(item.localFile)
            await queue.enqueueUpload(item)
        }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        await queue.run()

        for i in 0..<5 {
            #expect(try await store.exists(path: "library/a/\(i).flac") != nil)
        }
    }

    // MARK: - сверка expectedSha

    @Test func shaMismatchFailsWithoutRetry() async throws {
        let store = InMemoryRemoteStore()
        let log = EventLog()
        let sleeper = FakeSleeper()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: sleeper, maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let content = Data("real content".utf8)
        // expectedSha заведомо не совпадает с тем, что вернёт стор.
        let item = try backupItem(id: "m", content: content, path: "p", expectedSha: "0000ffff_неверный")
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        // Несовпадение sha — фатально (повтор аплоада даст тот же sha): finished failed.
        let states = log.states(for: "m")
        guard case .failed = states.last else {
            Issue.record("ожидался .failed при несовпадении sha, получено \(String(describing: states.last))")
            return
        }
        // Сверка sha — НЕ ретраябельна: сон не запрашивался.
        let slept = await sleeper.requestedDelays
        #expect(slept.isEmpty)
    }

    @Test func matchingShaPasses() async throws {
        let store = InMemoryRemoteStore()
        let log = EventLog()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let content = Data("verified".utf8)
        let item = try backupItem(id: "ok", content: content, path: "p", expectedSha: Sha256.hash(content))
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        guard case .done = log.states(for: "ok").last else {
            Issue.record("ожидался .done")
            return
        }
    }

    @Test func nilExpectedShaSkipsVerification() async throws {
        let store = InMemoryRemoteStore()
        let log = EventLog()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let content = Data("no-sha".utf8)
        let item = try backupItem(id: "ns", content: content, path: "p", expectedSha: nil)
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        guard case .done = log.states(for: "ns").last else {
            Issue.record("ожидался .done без сверки")
            return
        }
    }

    // MARK: - ретраи + backoff

    @Test func rateLimitedRetriesAfterSleepingThenSucceeds() async throws {
        // Стор, падающий с rateLimited(retryAfter:3) на первой попытке upload, успех со второй.
        let inner = InMemoryRemoteStore()
        let store = FlakyStore(inner: inner, failures: [.rateLimited(retryAfter: 3)])
        let log = EventLog()
        let sleeper = FakeSleeper()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: sleeper, maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let content = Data("retry me".utf8)
        let item = try backupItem(id: "r", content: content, path: "p", expectedSha: Sha256.hash(content))
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        // Уважён Retry-After: спал ≥3с.
        let slept = await sleeper.requestedDelays
        #expect(slept.count == 1)
        #expect(slept.first ?? 0 >= 3)

        // В итоге — успех.
        guard case .done = log.states(for: "r").last else {
            Issue.record("ожидался .done после ретрая")
            return
        }
    }

    @Test func unauthorizedFailsImmediatelyWithoutSleeping() async throws {
        let inner = InMemoryRemoteStore()
        let store = FlakyStore(inner: inner, failures: [.unauthorized])
        let log = EventLog()
        let sleeper = FakeSleeper()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: sleeper, maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let item = try backupItem(id: "u", content: Data("x".utf8), path: "p", expectedSha: nil)
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        // unauthorized нерекаверабелен → немедленный failed, без сна.
        guard case let .failed(error, _) = log.states(for: "u").last else {
            Issue.record("ожидался .failed")
            return
        }
        if case .unauthorized = error {} else {
            Issue.record("ожидался .unauthorized")
        }
        let slept = await sleeper.requestedDelays
        #expect(slept.isEmpty)
    }

    @Test func exhaustsRetriesThenFails() async throws {
        // Падает server(500) больше, чем maxAttempts.
        let inner = InMemoryRemoteStore()
        let failures = Array(repeating: RemoteError.server(status: 500), count: 10)
        let store = FlakyStore(inner: inner, failures: failures)
        let log = EventLog()
        let sleeper = FakeSleeper()
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 60)
        let queue = BackupQueue(store: store, policy: policy, sleeper: sleeper, maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let item = try backupItem(id: "e", content: Data("x".utf8), path: "p", expectedSha: nil)
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.run()

        // Исчерпав попытки — failed.
        guard case let .failed(_, attempt) = log.states(for: "e").last else {
            Issue.record("ожидался финальный .failed")
            return
        }
        #expect(attempt == 3)
        // Спал между попытками: maxAttempts=3 → 2 сна (1с, 2с).
        let slept = await sleeper.requestedDelays
        #expect(slept.count == 2)
        #expect(slept == [1, 2])
    }

    // MARK: - дедуп

    @Test func deduplicatesByID() async throws {
        let probe = ConcurrencyProbe()
        let store = ProbingStore(inner: InMemoryRemoteStore(), probe: probe)
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 2) { _, _ in }

        let content = Data("dup".utf8)
        let item = try backupItem(id: "same", content: content, path: "p", expectedSha: Sha256.hash(content))
        defer { try? FileManager.default.removeItem(at: item.localFile) }

        await queue.enqueueUpload(item)
        await queue.enqueueUpload(item) // тот же id — игнорируется
        await queue.enqueueUpload(item)
        await queue.run()

        // Аплоад выполнен ровно один раз.
        let count = await probe.uploadCount
        #expect(count == 1)
    }

    // MARK: - скачивание с resumeFrom

    @Test func downloadResumesFromExistingPrefix() async throws {
        let store = InMemoryRemoteStore()
        // Кладём в облако исходник.
        let content = Data("0123456789ABCDEF".utf8)
        let src = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await store.upload(localFile: src, to: "p") { _ in }

        // Частично скачанный файл — первые 10 байт уже на диске.
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-qdl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dst) }
        try content.prefix(10).write(to: dst)

        let log = EventLog()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let target = DownloadTarget(remotePath: "p", localFile: dst, resumeFrom: 10)
        await queue.enqueueDownload(id: "d1", target: target, expectedSha: Sha256.hash(content))
        await queue.run()

        let readBack = try Data(contentsOf: dst)
        #expect(readBack == content)
        guard case .done = log.states(for: "d1").last else {
            Issue.record("ожидался .done после докачки")
            return
        }
    }

    @Test func downloadResumesAfterTransientMidStreamFailure() async throws {
        // Источник в облаке.
        let store0 = InMemoryRemoteStore()
        let content = Data("0123456789ABCDEFGHIJKLMNOPQRSTUV".utf8) // 32 байта
        let src = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await store0.upload(localFile: src, to: "p") { _ in }

        // Декоратор: на 1-й попытке download дозапишет 5 байт хвоста и упадёт server(503),
        // на 2-й — реально докачает остаток.
        let store = PartialDownloadThenFailStore(inner: store0, partialTailBytes: 5)

        // Локальный приёмник: первые 8 байт уже скачаны ранее.
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-qdl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dst) }
        try content.prefix(8).write(to: dst)

        let log = EventLog()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        // resumeFrom фиксируется при enqueue = 8. После частичной записи на падающей попытке
        // файл вырастет до 13 байт. Если очередь повторно подаст resumeFrom=8 — inner снова
        // допишет хвост от 8 → файл перевалит за 32 байта и не сойдётся по sha. Корректно:
        // очередь пересчитывает offset от фактического размера (13) → дописывается ровно остаток.
        let target = DownloadTarget(remotePath: "p", localFile: dst, resumeFrom: 8)
        await queue.enqueueDownload(id: "dr", target: target, expectedSha: Sha256.hash(content))
        await queue.run()

        let readBack = try Data(contentsOf: dst)
        #expect(readBack == content)
        #expect(readBack.count == content.count)
        guard case .done = log.states(for: "dr").last else {
            Issue.record("ожидался .done после докачки с пересчётом смещения, получено \(String(describing: log.states(for: "dr").last))")
            return
        }
    }

    @Test func downloadShaMismatchFails() async throws {
        let store = InMemoryRemoteStore()
        let content = Data("payload".utf8)
        let src = try tempFile(content)
        defer { try? FileManager.default.removeItem(at: src) }
        _ = try await store.upload(localFile: src, to: "p") { _ in }

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("zver-qdl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dst) }

        let log = EventLog()
        let queue = BackupQueue(store: store, policy: RetryPolicy(), sleeper: FakeSleeper(), maxConcurrent: 1) {
            id, state in log.record(id, state)
        }
        let target = DownloadTarget(remotePath: "p", localFile: dst, resumeFrom: 0)
        await queue.enqueueDownload(id: "dm", target: target, expectedSha: "неверный")
        await queue.run()

        guard case .failed = log.states(for: "dm").last else {
            Issue.record("ожидался .failed при несовпадении sha скачивания")
            return
        }
    }
}
