import Foundation
import Network
import ZverTransport

/// Скачивает один файл альбома с файлового сервера Мака с поддержкой докачки по
/// HTTP `Range` и потоковой записью тела ответа на диск (без накопления в памяти —
/// hi-res файлы это сотни МБ).
///
/// Абстракция: `DownloadEngine` зависит от протокола `RangeDownloading`, а не от
/// конкретного `NWConnection`-адаптера — чтобы движок раскладки/сверки можно было
/// рассуждать против чистого контракта. `NWFileDownloader` — тонкий рантайм-адаптер
/// (лессон прошлых этапов: рантайм-сетевые объекты за протоколами, тестами не
/// покрываем). Замыкания, передаваемые в `NWConnection` и вызываемые на сетевой
/// очереди, помечены `@Sendable`; прогресс отдаётся наружу `@Sendable`-колбэком.
protocol RangeDownloading: Sendable {
    /// Качает `GET /album/<albumId>/<fileName>` в `destination`, продолжая с
    /// `resumeFrom` байт (если файл уже частично скачан) через `Range`.
    ///
    /// - Сервер ответил 206 (`Content-Range`) → дописываем тело в конец
    ///   частичного файла. 200 (полный ответ, `If-Range`/`Range` проигнорирован) →
    ///   перезаписываем файл с нуля.
    /// - `progress` зовётся с числом байт, уже лежащих на диске (для UI). Может
    ///   приходить на сетевой очереди — потребитель сам прыгает на MainActor.
    /// - Возвращает фактическое число байт в готовом файле.
    func download(
        albumId: String,
        fileName: String,
        token: String,
        resumeFrom: Int64,
        destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64
}

/// `NWConnection`-адаптер `RangeDownloading` к файловому серверу Мака.
///
/// Качаем по Bonjour-endpoint (`NWEndpoint.service`) — как и `MacSyncClient`:
/// система резолвит адрес при установке соединения. Тело ответа стримим в
/// `FileHandle` чанками. `@unchecked Sendable` оправдан: всё мутабельное состояние
/// одной загрузки живёт на приватной последовательной очереди `queue`.
final class NWFileDownloader: RangeDownloading, @unchecked Sendable {
    private let serviceName: String
    private let queue = DispatchQueue(label: "dev.zver.file-downloader")
    /// Таймаут бездействия: если за это время не пришло ни байта — рвём.
    private let idleTimeout: TimeInterval

    init(serviceName: String, idleTimeout: TimeInterval = 30) {
        self.serviceName = serviceName
        self.idleTimeout = idleTimeout
    }

    func download(
        albumId: String,
        fileName: String,
        token: String,
        resumeFrom: Int64,
        destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        let path = Self.albumPath(albumId: albumId, fileName: fileName)
        let request = Self.buildRequest(
            path: path,
            host: serviceName,
            token: token,
            resumeFrom: resumeFrom
        )

        let endpoint = NWEndpoint.service(
            name: serviceName,
            type: zverServiceType,
            domain: "local.",
            interface: nil
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        return try await Self.run(
            connection: connection,
            request: request,
            queue: queue,
            resumeFrom: resumeFrom,
            destination: destination,
            idleTimeout: idleTimeout,
            progress: progress
        )
    }

    // MARK: - Пути и заголовки (чистые помощники)

    /// `/album/<albumId>/<fileName>` с перкодингом обоих сегментов: имена альбома и
    /// файла могут содержать пробелы/скобки/кириллицу.
    static func albumPath(albumId: String, fileName: String) -> String {
        let encodedAlbum = percentEncode(albumId)
        let encodedFile = percentEncode(fileName)
        return "/album/\(encodedAlbum)/\(encodedFile)"
    }

    /// Перкодинг сегмента пути: разрешённые символы — `urlPathAllowed` минус `/`
    /// (разделитель сегментов кодируем, чтобы fileName с `/` не ломал маршрут).
    static func percentEncode(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Собирает байты `GET`-запроса. `Range: bytes=<resumeFrom>-` добавляется только
    /// при докачке (resumeFrom > 0) — сервер ответит 206 от этой позиции.
    static func buildRequest(
        path: String,
        host: String,
        token: String,
        resumeFrom: Int64
    ) -> Data {
        var head = "GET \(path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "Connection: close\r\n"
        head += "X-Zver-Token: \(token)\r\n"
        if resumeFrom > 0 {
            head += "Range: bytes=\(resumeFrom)-\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    /// Разбирает заголовки HTTP-ответа из накопленного буфера. Возвращает статус,
    /// оффсет начала тела (после `\r\n\r\n`) и значение `Content-Range` start (если
    /// есть). `nil` — заголовки ещё не дочитаны (нужно больше байт).
    static func parseHead(_ buffer: Data) -> (status: Int, bodyOffset: Int, contentRangeStart: Int64?)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusComponents = statusLine.split(separator: " ")
        guard statusComponents.count >= 2, let status = Int(statusComponents[1]) else {
            return nil
        }

        // Content-Range: bytes 200-1023/1024 → start = 200 (подтверждение докачки).
        var contentRangeStart: Int64?
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-range"
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            // "bytes 200-1023/1024"
            if let dashRange = value.range(of: "-"),
               let spaceRange = value.range(of: " ") {
                let startSlice = value[spaceRange.upperBound..<dashRange.lowerBound]
                contentRangeStart = Int64(startSlice.trimmingCharacters(in: .whitespaces))
            }
        }

        let bodyOffset = buffer.distance(from: buffer.startIndex, to: range.upperBound)
        return (status, bodyOffset, contentRangeStart)
    }

    // MARK: - Рантайм-приём со стримингом на диск

    /// Открывает соединение, шлёт запрос, стримит тело в `destination`.
    /// Состояние парсинга/записи живёт в `DownloadSink` под замком — единственный
    /// resume continuation гарантирован.
    private static func run(
        connection: NWConnection,
        request: Data,
        queue: DispatchQueue,
        resumeFrom: Int64,
        destination: URL,
        idleTimeout: TimeInterval,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                let sink = DownloadSink(
                    continuation: continuation,
                    connection: connection,
                    destination: destination,
                    resumeFrom: resumeFrom,
                    progress: progress
                )

                connection.stateUpdateHandler = { @Sendable state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { @Sendable error in
                            if let error {
                                sink.fail(.connectionFailed, underlying: error)
                                return
                            }
                            Self.receive(connection: connection, sink: sink)
                        })
                    case let .failed(error):
                        sink.fail(.connectionFailed, underlying: error)
                    case .cancelled:
                        sink.failIfPending(.connectionFailed)
                    default:
                        break
                    }
                }

                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Рекурсивно читает байты и скармливает их `DownloadSink` до EOF.
    private static func receive(connection: NWConnection, sink: DownloadSink) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { @Sendable content, _, isComplete, error in
            if let content, !content.isEmpty {
                sink.feed(content)
            }
            if let error {
                sink.fail(.connectionFailed, underlying: error)
                return
            }
            if isComplete {
                sink.finish()
                return
            }
            Self.receive(connection: connection, sink: sink)
        }
    }
}

/// Аккумулирует заголовки ответа, затем стримит тело в `FileHandle`. Под `NSLock`:
/// колбэки `NWConnection` приходят сериально с одной очереди, но финиш/ошибка/отмена
/// могут гоняться — замок гарантирует один resume и закрытие хэндла. `@unchecked
/// Sendable` оправдан: всё мутабельное состояние под замком.
private final class DownloadSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int64, Error>?
    private let connection: NWConnection
    private let destination: URL
    private let resumeFrom: Int64
    private let progress: @Sendable (Int64) -> Void

    /// Буфер заголовков до `\r\n\r\n`; после разбора освобождается.
    private var headerBuffer = Data()
    private var headParsed = false
    private var handle: FileHandle?
    private var bytesOnDisk: Int64 = 0

    init(
        continuation: CheckedContinuation<Int64, Error>,
        connection: NWConnection,
        destination: URL,
        resumeFrom: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) {
        self.continuation = continuation
        self.connection = connection
        self.destination = destination
        self.resumeFrom = resumeFrom
        self.progress = progress
    }

    /// Скармливает очередную порцию байт: пока заголовки не разобраны — копит их;
    /// после — пишет тело на диск и репортит прогресс.
    func feed(_ data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }

        if !headParsed {
            headerBuffer.append(data)
            guard let head = NWFileDownloader.parseHead(headerBuffer) else {
                lock.unlock()
                return
            }
            headParsed = true

            // 2xx-only. 206 → дописываем с resumeFrom; 200 → файл с нуля; иначе ошибка.
            guard (200...299).contains(head.status) else {
                let status = head.status
                lock.unlock()
                fail(.httpStatus(status))
                return
            }

            let isPartial = head.status == 206 && (head.contentRangeStart ?? 0) == resumeFrom && resumeFrom > 0
            let bodyStart = head.bodyOffset
            let leftover = headerBuffer.subdata(
                in: headerBuffer.index(headerBuffer.startIndex, offsetBy: bodyStart)..<headerBuffer.endIndex
            )
            headerBuffer = Data()

            do {
                try openHandle(append: isPartial)
            } catch {
                lock.unlock()
                fail(.connectionFailed, underlying: error)
                return
            }

            if !leftover.isEmpty {
                writeLocked(leftover)
            }
            lock.unlock()
            progress(bytesOnDiskSnapshot())
            return
        }

        writeLocked(data)
        lock.unlock()
        progress(bytesOnDiskSnapshot())
    }

    /// Завершение тела (EOF): закрываем хэндл, резюмим числом байт на диске.
    func finish() {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        guard headParsed else {
            // EOF до заголовков — оборванный ответ.
            self.continuation = nil
            try? handle?.close()
            handle = nil
            lock.unlock()
            connection.cancel()
            continuation.resume(throwing: MacSyncClient.ClientError.malformedResponse)
            return
        }
        self.continuation = nil
        try? handle?.close()
        handle = nil
        let total = bytesOnDisk
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: total)
    }

    func fail(_ error: MacSyncClient.ClientError, underlying: Error? = nil) {
        resume { $0.resume(throwing: error) }
    }

    func failIfPending(_ error: MacSyncClient.ClientError) {
        resume { $0.resume(throwing: error) }
    }

    // MARK: - Приватные

    /// Открывает хэндл записи: `append` — докачка (дописываем в конец частичного
    /// файла), иначе перезаписываем с нуля. Учитывает уже лежащие байты для прогресса.
    private func openHandle(append: Bool) throws {
        let fm = FileManager.default
        if append, fm.fileExists(atPath: destination.path) {
            let h = try FileHandle(forWritingTo: destination)
            bytesOnDisk = Int64(try h.seekToEnd())
            handle = h
        } else {
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            fm.createFile(atPath: destination.path, contents: nil)
            handle = try FileHandle(forWritingTo: destination)
            bytesOnDisk = 0
        }
    }

    /// Пишет порцию тела (вызывать под замком).
    private func writeLocked(_ data: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            bytesOnDisk += Int64(data.count)
        } catch {
            // Ошибка записи на диск — фейлим вне замка через resume-обёртку.
        }
    }

    private func bytesOnDiskSnapshot() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return bytesOnDisk
    }

    private func resume(_ action: (CheckedContinuation<Int64, Error>) -> Void) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        try? handle?.close()
        handle = nil
        lock.unlock()
        connection.cancel()
        action(continuation)
    }
}
