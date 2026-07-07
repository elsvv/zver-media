import Foundation
import ZverImport

/// Рантайм-загрузчик файлов Internet Archive поверх `URLSession` с докачкой по HTTP
/// `Range`. Тонкий сетевой адаптер (образец — `NWFileDownloader`/`DownloadEngine`):
/// чистая логика (построение URL, разбор метаданных, фильтр форматов, раскладка тела на
/// диск — `ArchiveFileSink`) живёт в `ZverImport`; здесь — перенос байт с сети в приёмник,
/// диспозиция по статусу и прогресс.
///
/// Тело ответа **стримим на диск** через `URLSessionDataTask` (а не `downloadTask`):
/// `downloadTask` пишет тело во внутренний temp системы и отдаёт его только в
/// `didFinishDownloadingTo` при ПОЛНОМ успехе — при обрыве temp отбрасывается, и докачка
/// не работала бы (частичного файла на диске нет). С `dataTask` частичный префикс остаётся
/// в `destination`, поэтому следующая попытка стартует с `ArchiveFileSink.partialSize` и
/// просит хвост заголовком `Range`.
///
/// Один экземпляр обслуживает последовательную очередь `ArchiveDownloadCenter` (файлы
/// качаются по одному). `@unchecked Sendable`: всё мутабельное состояние активных
/// загрузок — под `lock`, а `URLSession` потокобезопасна.
final class ArchiveDownloader: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // Тело стримим на диск — кэш ответа не нужен и вреден (hi-res FLAC сотни МБ).
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Состояние одной активной загрузки (ключ — `taskIdentifier`).
    private final class Job {
        let continuation: CheckedContinuation<Void, Error>
        let resumeFrom: Int64
        /// Полный размер файла из метаданных (для доли прогресса); nil → по данным ответа.
        let expectedTotal: Int64?
        let progress: @Sendable (Double) -> Void
        let sink: ArchiveFileSink
        /// Полный размер по `Content-Length` ответа — fallback, если метаданные без size.
        var responseTotal: Int64?
        /// Ошибка (не-2xx или запись на диск) — фейлим ею в `didComplete` поверх
        /// синтетической ошибки отмены таска.
        var failure: Error?

        init(
            continuation: CheckedContinuation<Void, Error>,
            destination: URL,
            resumeFrom: Int64,
            expectedTotal: Int64?,
            progress: @escaping @Sendable (Double) -> Void
        ) {
            self.continuation = continuation
            self.resumeFrom = resumeFrom
            self.expectedTotal = expectedTotal
            self.progress = progress
            self.sink = ArchiveFileSink(destination: destination)
        }

        /// Доля готовности файла: байты на диске к полному размеру (из метаданных или из
        /// `Content-Length`). Без известного размера — 0 (доля неопределима).
        func fraction() -> Double {
            guard let total = expectedTotal ?? responseTotal, total > 0 else { return 0 }
            return min(1.0, Double(sink.bytesOnDisk) / Double(total))
        }
    }
    private var jobs: [Int: Job] = [:]

    /// Качает `url` в `destination`, дописывая уже скачанный префикс через `Range`
    /// (если он есть). `expectedBytes` — полный размер файла (для доли прогресса).
    /// Бросает `ArchiveFileSink.DownloadError.http` на не-2xx и транспортные ошибки
    /// `URLSession` (обрыв соединения → частичный префикс остаётся на диске).
    func download(
        from url: URL,
        to destination: URL,
        expectedBytes: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let resumeFrom = ArchiveFileSink.partialSize(destination)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        // Докачка: просим хвост от уже лежащего префикса — сервер ответит 206.
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.dataTask(with: request)
                let job = Job(
                    continuation: cont, destination: destination, resumeFrom: resumeFrom,
                    expectedTotal: expectedBytes, progress: progress)
                lock.lock()
                jobs[task.taskIdentifier] = job
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            // Очередь последовательная — активна одна задача; рвём все на всякий случай.
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
    }
}

extension ArchiveDownloader: URLSessionDataDelegate {
    /// Пришли заголовки — открываем приёмник по статусу/позиции докачки и решаем
    /// диспозицию: 2xx → продолжаем приём тела; не-2xx → отменяем (частичный префикс не
    /// тронут), фейлим `DownloadError.http` в `didComplete`.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyLength = response.expectedContentLength   // длина тела, -1 если неизвестна

        lock.lock()
        guard let job = jobs[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        do {
            try job.sink.open(status: status, resumeFrom: job.resumeFrom)
        } catch {
            job.failure = error
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        // Fallback-оценка полного размера, если метаданные не дали size: у 206 тело — это
        // хвост от resumeFrom, у 200 — весь файл.
        if bodyLength > 0 {
            job.responseTotal = (status == 206 && job.resumeFrom > 0)
                ? job.resumeFrom + bodyLength : bodyLength
        }
        let fraction = job.fraction()
        let progress = job.progress
        lock.unlock()

        progress(fraction)   // при докачке доля стартует не с нуля — сразу покажем префикс
        completionHandler(.allow)
    }

    /// Порция тела — стримим на диск и репортим прогресс.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let job = jobs[dataTask.taskIdentifier], job.failure == nil else { lock.unlock(); return }
        do {
            try job.sink.write(data)
        } catch {
            job.failure = error
            lock.unlock()
            dataTask.cancel()   // прекращаем приём — didComplete зафейлит ошибкой записи
            return
        }
        let fraction = job.fraction()
        let progress = job.progress
        lock.unlock()
        progress(fraction)
    }

    /// Завершение таска: закрываем приёмник и резюмим continuation. Записанная ошибка
    /// (`DownloadError.http`/запись) приоритетнее синтетической ошибки отмены таска.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { lock.unlock(); return }
        job.sink.close()
        let failure = job.failure
        lock.unlock()

        if let failure {
            job.continuation.resume(throwing: failure)
        } else if let error {
            job.continuation.resume(throwing: error)
        } else {
            job.continuation.resume()
        }
    }
}
