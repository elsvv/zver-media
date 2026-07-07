import Foundation
import ZverImport

/// Рантайм-загрузчик файлов Internet Archive поверх `URLSession` с докачкой по HTTP
/// `Range`. Тонкий сетевой адаптер (образец — `DownloadEngine`/`URLSessionHTTPClient`):
/// чистая логика (построение URL, разбор метаданных, фильтр форматов) живёт в
/// `ZverImport`; здесь — перенос байт на диск, диспозиция по статусу и прогресс.
/// Тестами не покрываем (рантайм-сеть за делегатом — лессон прошлых этапов), проверяется
/// компиляцией.
///
/// Один экземпляр обслуживает последовательную очередь `ArchiveDownloadCenter` (файлы
/// качаются по одному). `@unchecked Sendable`: всё мутабельное состояние активных
/// загрузок — под `lock`, а `URLSession` потокобезопасна.
final class ArchiveDownloader: NSObject, @unchecked Sendable {
    /// Ошибка загрузки файла.
    enum DownloadError: Error {
        /// Сервер вернул не-2xx (частичный файл при этом не тронут — докачка переживёт).
        case http(Int)
    }

    private let lock = NSLock()
    private lazy var session: URLSession = URLSession(
        configuration: .default, delegate: self, delegateQueue: nil)

    /// Состояние одной активной загрузки (ключ — `taskIdentifier`).
    private struct Job {
        let continuation: CheckedContinuation<Void, Error>
        let destination: URL
        let resumeFrom: Int64
        /// Полный размер файла из метаданных (для доли прогресса); nil → по данным задачи.
        let expectedTotal: Int64?
        let progress: @Sendable (Double) -> Void
        /// Ошибка раскладки файла в `didFinishDownloadingTo` — фейлим ею в `didComplete`.
        var finishError: Error?
    }
    private var jobs: [Int: Job] = [:]

    /// Качает `url` в `destination`, дописывая уже скачанный префикс через `Range`
    /// (если он есть). `expectedBytes` — полный размер файла (для доли прогресса).
    /// Бросает `DownloadError.http` на не-2xx и транспортные ошибки `URLSession`.
    func download(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let resumeFrom = Self.partialSize(destination)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        // Докачка: просим хвост от уже лежащего префикса — сервер ответит 206.
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: request)
                lock.lock()
                jobs[task.taskIdentifier] = Job(
                    continuation: cont, destination: destination, resumeFrom: resumeFrom,
                    expectedTotal: expectedBytes, progress: progress, finishError: nil)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            // Очередь последовательная — активна одна задача; рвём все на всякий случай.
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
    }

    // MARK: - Файловые помощники

    /// Размер уже скачанного частичного файла (0, если файла нет) — позиция докачки.
    static func partialSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Раскладывает тело задачи на место по статусу: 206 при существующем префиксе —
    /// дописываем хвост; 200/новый файл — перезаписываем целиком; не-2xx — не трогаем
    /// приёмник и бросаем (частичный префикс переживает транзиентный сбой).
    static func materialize(from tempURL: URL, to destination: URL, status: Int, resumeFrom: Int64) throws {
        let fm = FileManager.default
        guard (200..<300).contains(status) else { throw DownloadError.http(status) }

        if status == 206, resumeFrom > 0, fm.fileExists(atPath: destination.path) {
            let tail = try FileHandle(forReadingFrom: tempURL)
            defer { try? tail.close() }
            let out = try FileHandle(forWritingTo: destination)
            defer { try? out.close() }
            try out.seekToEnd()
            while true {
                let chunk = try tail.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try out.write(contentsOf: chunk)
            }
        } else {
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: tempURL, to: destination)
        }
    }
}

extension ArchiveDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        guard let job = jobs[downloadTask.taskIdentifier] else { lock.unlock(); return }
        let expectedTotal = job.expectedTotal
        let resumeFrom = job.resumeFrom
        let progress = job.progress
        lock.unlock()

        let fraction: Double
        if let expectedTotal, expectedTotal > 0 {
            // Доля по полному размеру: уже лежащий префикс + скачанный хвост.
            fraction = min(1.0, Double(resumeFrom + totalBytesWritten) / Double(expectedTotal))
        } else if totalBytesExpectedToWrite > 0 {
            fraction = min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            fraction = 0
        }
        progress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Раскладываем ДО завершения таска — `location` валиден только здесь.
        lock.lock()
        guard var job = jobs[downloadTask.taskIdentifier] else { lock.unlock(); return }
        lock.unlock()

        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            try ArchiveDownloader.materialize(
                from: location, to: job.destination, status: status, resumeFrom: job.resumeFrom)
        } catch {
            job.finishError = error
            lock.lock(); jobs[downloadTask.taskIdentifier] = job; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        lock.unlock()

        if let error {
            job.continuation.resume(throwing: error)
        } else if let finishError = job.finishError {
            job.continuation.resume(throwing: finishError)
        } else {
            job.continuation.resume()
        }
    }
}
