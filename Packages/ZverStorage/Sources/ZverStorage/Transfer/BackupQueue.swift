import Foundation
import ZverTransport

/// Актор-планировщик облачных передач: оркеструет ``RemoteStore``, держит ≤`maxConcurrent`
/// активных задач, ретраит по ``RetryPolicy`` через инъецированный ``Sleeper`` и сверяет
/// облачный SHA-256 с ожидаемым.
///
/// НЕ сетевой сам по себе — вся сеть за инъецированным ``RemoteStore`` (в тестах —
/// ``InMemoryRemoteStore``). FIFO-порядок приёма с дедупом по `id`: повторный enqueue
/// того же `id` игнорируется. На каждой стадии эмитит `(itemId, TransferState)` через
/// `@Sendable`-колбэк — потребитель (S4-10) мапит события в каталожный `fileState`.
///
/// Один тип обслуживает оба направления (`.upload`/`.download`) — общий конвейер
/// «href → передача → сверка sha → done», отличается лишь вызовом `store.upload` vs
/// `store.download(resumeFrom:)`.
public actor BackupQueue {
    /// Направление передачи.
    private enum Direction: Sendable {
        case upload(BackupItem)
        case download(id: String, target: DownloadTarget, expectedSha: String?)

        var id: String {
            switch self {
            case let .upload(item): return item.id
            case let .download(id, _, _): return id
            }
        }
    }

    private let store: any RemoteStore
    private let policy: RetryPolicy
    private let sleeper: any Sleeper
    private let maxConcurrent: Int
    private let onEvent: @Sendable (String, TransferState) -> Void

    /// Ожидающие старта задачи в порядке приёма (FIFO).
    private var pending: [Direction] = []
    /// Все `id`, когда-либо принятые (для дедупа повторного enqueue).
    private var seenIDs: Set<String> = []

    /// - Parameters:
    ///   - store: облачное хранилище за протоколом (в тестах — `InMemoryRemoteStore`).
    ///   - policy: политика ретраев (классификация + backoff).
    ///   - sleeper: реализация ожидания (в тестах — `FakeSleeper`, мгновенный).
    ///   - maxConcurrent: максимум одновременных передач (дефолт 2; Яндекс допускает ≤4,
    ///     для личного приложения берём 2).
    ///   - onEvent: колбэк состояния `(itemId, TransferState)`; вызывается с произвольной
    ///     задачи (`@Sendable`) — потребитель сам прыгает на нужный актор/`MainActor`.
    public init(
        store: any RemoteStore,
        policy: RetryPolicy = RetryPolicy(),
        sleeper: any Sleeper = TaskSleeper(),
        maxConcurrent: Int = 2,
        onEvent: @escaping @Sendable (String, TransferState) -> Void
    ) {
        self.store = store
        self.policy = policy
        self.sleeper = sleeper
        self.maxConcurrent = max(1, maxConcurrent)
        self.onEvent = onEvent
    }

    // MARK: - приём задач

    /// Ставит выгрузку в очередь. Повтор того же `id` игнорируется (дедуп).
    public func enqueueUpload(_ item: BackupItem) {
        enqueue(.upload(item))
    }

    /// Ставит загрузку (скачивание) в очередь с докачкой от `target.resumeFrom`.
    /// Повтор того же `id` игнорируется (дедуп).
    public func enqueueDownload(id: String, target: DownloadTarget, expectedSha: String?) {
        enqueue(.download(id: id, target: target, expectedSha: expectedSha))
    }

    private func enqueue(_ direction: Direction) {
        let id = direction.id
        guard !seenIDs.contains(id) else { return }
        seenIDs.insert(id)
        pending.append(direction)
        onEvent(id, .queued)
    }

    /// Извлекает следующую задачу (FIFO) или `nil`, если очередь пуста.
    private func nextPending() -> Direction? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    // MARK: - дренаж очереди

    /// Обрабатывает все принятые задачи, держа не более `maxConcurrent` параллельно,
    /// и возвращается, когда очередь опустела и все активные передачи завершились.
    ///
    /// Реентерабельно: задачи, добавленные во время дренажа (напр. бэкап каталога после
    /// батча), подхватываются тем же забегом, пока есть свободные слоты.
    public func run() async {
        await withTaskGroup(of: Void.self) { group in
            var launched = 0
            while launched < maxConcurrent, let direction = nextPending() {
                launched += 1
                group.addTask { [self] in await process(direction) }
            }
            // По мере завершения каждой задачи запускаем следующую из очереди.
            while await group.next() != nil {
                if let direction = nextPending() {
                    group.addTask { [self] in await process(direction) }
                }
            }
        }
    }

    // MARK: - конвейер одной задачи

    private func process(_ direction: Direction) async {
        let id = direction.id
        var attempt = 0

        while true {
            attempt += 1
            onEvent(id, .requestingHref)
            do {
                let resource = try await performTransfer(direction)
                onEvent(id, .verifying)
                if let expected = expectedSha(of: direction) {
                    guard let cloudSha = resource.sha256, cloudSha == expected else {
                        // Несовпадение sha фатально: повтор той же передачи даст тот же
                        // sha. Сразу в failed, без ретрая и без сна.
                        onEvent(id, .failed(.badResponse, attempt: attempt))
                        return
                    }
                }
                onEvent(id, .done(resource))
                return
            } catch let error as RemoteError {
                if policy.isRetryable(error), policy.shouldRetry(attempt: attempt + 1) {
                    let retryAfter = retryAfterSeconds(error)
                    let delay = policy.delay(forAttempt: attempt, retryAfter: retryAfter)
                    await sleeper.sleep(delay)
                    continue
                }
                onEvent(id, .failed(error, attempt: attempt))
                return
            } catch {
                // Любая не-`RemoteError` (теоретически) — заворачиваем как транспорт и
                // не ретраим (классификатор сочтёт transport ретраябельным, но без
                // контекста кейса безопаснее завершить).
                onEvent(id, .failed(.transport(underlying: error), attempt: attempt))
                return
            }
        }
    }

    /// Выполняет фактическую передачу (одну попытку), эмитя прогресс. Бросает `RemoteError`.
    private func performTransfer(_ direction: Direction) async throws -> RemoteResource {
        let id = direction.id
        let onEvent = self.onEvent
        let progress: @Sendable (Int64) -> Void = { bytes in
            onEvent(id, .transferring(bytesSent: bytes))
        }
        switch direction {
        case let .upload(item):
            // Идемпотентно гарантируем родительскую папку перед PUT.
            try await store.ensureFolder(path: parentFolder(of: item.remotePath))
            return try await store.upload(localFile: item.localFile, to: item.remotePath, progress: progress)
        case let .download(_, target, _):
            return try await store.download(
                path: target.remotePath,
                to: target.localFile,
                resumeFrom: target.resumeFrom,
                progress: progress
            )
        }
    }

    private func expectedSha(of direction: Direction) -> String? {
        switch direction {
        case let .upload(item): return item.expectedSha
        case let .download(_, _, expectedSha): return expectedSha
        }
    }

    private func retryAfterSeconds(_ error: RemoteError) -> TimeInterval? {
        if case let .rateLimited(retryAfter) = error { return retryAfter }
        return nil
    }

    /// Родительская папка пути `library/<albumId>/<file>` → `library/<albumId>`.
    /// Корневой путь без `/` → пустая строка (адаптер трактует как корень).
    private func parentFolder(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<idx])
    }
}
