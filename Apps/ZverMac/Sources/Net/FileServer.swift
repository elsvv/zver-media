import Foundation
import Network
import ZverTransport

/// HTTP-сервер раздачи альбомов телефону поверх `NWListener` (Network.framework).
///
/// Принимает TCP-соединения, кормит байты `HTTPRequestParser`, по `HTTPRouter`
/// обслуживает протокол синка:
/// - `GET  /manifest`                → JSON манифеста очереди (нужен `X-Zver-Token`);
/// - `GET  /album/<id>/<file>`       → файл потоково через `FileHandle` чанками с
///   учётом `ByteRange`/206/`Content-Range`/`Accept-Ranges`/`ETag`(=sha256)/`If-Range`;
/// - `POST /pair    { code }`        → `{ token }` (только в открытом окне pairing);
/// - `POST /confirm { albumId }`     → 200, альбом снимается с очереди.
/// Авторизация `X-Zver-Token` обязательна на всех маршрутах, кроме `/pair`.
/// Один доверенный клиент в LAN; принимаются только GET и POST pair/confirm.
///
/// Bonjour: этот же слушатель публикует `_zver._tcp` (через `listener.service`),
/// если в `start(serviceName:txt:)` передано имя сервиса — отдельный второй
/// `NWListener` на том же порту не нужен (он дал бы EADDRINUSE).
///
/// Concurrency (краш-класс Swift 6): ВСЕ колбэки `NWListener`/`NWConnection` —
/// `@Sendable`, исполняются на сетевой очереди `queue`. Чтение раздаваемого
/// состояния и проверка токенов — потокобезопасно через `HostState` (под замком),
/// без захода на `@MainActor`. Переход в модель (`confirm`) делает приложение
/// через переданный `@Sendable`-замыкание `onConfirm`, внутри которого
/// `Task { @MainActor in … }`. Сам `NWListener` тут не наследует UI-изоляцию.
///
/// `@unchecked Sendable` оправдан: мутабельный `listener` живёт на `queue`,
/// остальное состояние — иммутабельные ссылки/`HostState` под замком.
final class FileServer: @unchecked Sendable {
    /// Потокобезопасное раздаваемое состояние (снимок очереди + токены + pairing).
    private let state: HostState
    /// Колбэк подтверждения доставки альбома (`POST /confirm`). Приложение внутри
    /// прыгает на `@MainActor`. Возврат — был ли альбом в очереди (для логов).
    private let onConfirm: @Sendable (String) -> Void
    /// Сетевая очередь для слушателя и всех соединений.
    private let queue = DispatchQueue(label: "dev.zver.file-server")
    /// Размер чанка потоковой отдачи файла (1 МБ) — hi-res не грузим в память.
    private let chunkSize: Int

    private var listener: NWListener?

    init(state: HostState,
         chunkSize: Int = 1 << 20,
         onConfirm: @escaping @Sendable (String) -> Void) {
        self.state = state
        self.chunkSize = chunkSize
        self.onConfirm = onConfirm
    }

    // MARK: - Жизненный цикл слушателя

    /// Запускает сервер. `port` = nil → система выбирает свободный порт; его
    /// фактическое значение приходит в `onReady`. Колбэки — `@Sendable`, на
    /// сетевой очереди.
    ///
    /// Bonjour-анонс вешается на ЭТОТ ЖЕ слушатель (`listener.service`) до старта —
    /// один `NWListener` и принимает соединения, и публикует `_zver._tcp` с TXT.
    /// Так задумано в Network.framework; отдельный второй слушатель на том же
    /// порту дал бы EADDRINUSE (см. фикс ревью S3-9). Если `serviceName == nil` —
    /// сервер слушает без публикации (превью/тесты сборки).
    func start(port: UInt16? = nil,
               serviceName: String? = nil,
               txt: [String: String] = [:],
               onReady: @escaping @Sendable (UInt16) -> Void,
               onFailure: @escaping @Sendable (Error) -> Void) {
        stop()

        let parameters = NWParameters.tcp
        let nwPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            onFailure(error)
            return
        }

        // Публикуем Bonjour на этом же слушателе — без второго bind на тот же порт.
        if let serviceName {
            listener.service = NWListener.Service(
                name: serviceName,
                type: zverServiceType,
                txtRecord: NWTXTRecord(txt)
            )
        }

        let chunkSize = self.chunkSize
        let state = self.state
        let onConfirm = self.onConfirm
        let connectionQueue = self.queue

        listener.stateUpdateHandler = { @Sendable state in
            switch state {
            case .ready:
                if let rawPort = listener.port?.rawValue {
                    onReady(rawPort)
                }
            case let .failed(error):
                onFailure(error)
            default:
                break
            }
        }

        // Новое соединение: заводим обработчик, который сам стартует приём на
        // сетевой очереди сервера.
        listener.newConnectionHandler = { @Sendable connection in
            let handler = ConnectionHandler(
                connection: connection,
                state: state,
                chunkSize: chunkSize,
                queue: connectionQueue,
                onConfirm: onConfirm
            )
            handler.start()
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    /// Останавливает сервер (закрывает слушатель). Активные соединения завершатся
    /// сами по `Connection: close` или будут отменены системой.
    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Обработчик одного соединения: накапливает HTTP-запрос, обслуживает один
/// маршрут и закрывает соединение (`Connection: close`).
///
/// Состояние (буфер тела, разобранный запрос, открытый `FileHandle` для отдачи)
/// под `NSLock`: колбэки `NWConnection` приходят сериально с одной очереди, но
/// финиш/ошибка могут гоняться — замок гарантирует один путь завершения.
/// `@unchecked Sendable` оправдан: всё мутабельное под замком, замыкания `@Sendable`.
private final class ConnectionHandler: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private let state: HostState
    private let chunkSize: Int
    private let queue: DispatchQueue
    private let onConfirm: @Sendable (String) -> Void

    /// Инкрементальный парсер заголовков запроса.
    private var parser = HTTPRequestParser()
    /// Разобранный запрос (после полного заголовочного блока).
    private var request: HTTPRequest?
    /// Накопленные байты тела (для POST) после терминатора заголовков.
    private var bodyBuffer = Data()
    /// Сколько байт тела ещё ждём (по `Content-Length`).
    private var bodyRemaining = 0
    /// Сырой буфер до того, как заголовки разобраны (нужен, чтобы отделить тело).
    private var rawBuffer = Data()
    private var headersParsed = false
    private var finished = false

    init(connection: NWConnection,
         state: HostState,
         chunkSize: Int,
         queue: DispatchQueue,
         onConfirm: @escaping @Sendable (String) -> Void) {
        self.connection = connection
        self.state = state
        self.chunkSize = chunkSize
        self.queue = queue
        self.onConfirm = onConfirm
    }

    /// Запускает приём: открывает соединение и начинает читать запрос.
    func start() {
        connection.stateUpdateHandler = { @Sendable [weak self] newState in
            switch newState {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Рекурсивно читает байты запроса с сетевой очереди.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            @Sendable [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                self.ingest(content)
            }
            if error != nil {
                self.close()
                return
            }
            if self.shouldKeepReading() {
                if isComplete {
                    // EOF до полного запроса — клиент оборвал, закрываемся.
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    /// Обрабатывает очередную порцию байт: дочитывает заголовки, затем тело.
    /// Когда запрос целиком собран — диспатчит его (один раз).
    private func ingest(_ data: Data) {
        lock.lock()
        if finished { lock.unlock(); return }

        if !headersParsed {
            rawBuffer.append(data)
            switch parser.feed(data) {
            case .needMore:
                lock.unlock()
                return
            case let .request(req):
                headersParsed = true
                request = req
                bodyRemaining = req.contentLength
                // Отделяем уже принятые байты тела (всё после CRLFCRLF).
                if let bodyStart = Self.bodyOffset(in: rawBuffer) {
                    let leftover = rawBuffer.subdata(in: rawBuffer.index(rawBuffer.startIndex, offsetBy: bodyStart)..<rawBuffer.endIndex)
                    appendBodyLocked(leftover)
                }
                rawBuffer = Data()
            }
        } else {
            appendBodyLocked(data)
        }

        // Готов ли запрос к обработке (тело дочитано)?
        guard headersParsed, bodyRemaining <= 0, let req = request else {
            lock.unlock()
            return
        }
        finished = true
        let body = bodyBuffer
        lock.unlock()

        dispatch(req, body: body)
    }

    /// Добавляет байты тела, уменьшая остаток `Content-Length` (вызывать под замком).
    private func appendBodyLocked(_ data: Data) {
        guard bodyRemaining > 0 else { return }
        let take = min(data.count, bodyRemaining)
        bodyBuffer.append(data.prefix(take))
        bodyRemaining -= take
    }

    /// Нужно ли читать ещё байты (запрос не собран и соединение не завершено).
    private func shouldKeepReading() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        if !headersParsed { return true }
        return bodyRemaining > 0
    }

    /// Смещение начала тела (сразу за `\r\n\r\n`) в сыром буфере, либо nil.
    private static func bodyOffset(in buffer: Data) -> Int? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = buffer.range(of: terminator) else { return nil }
        return buffer.distance(from: buffer.startIndex, to: range.upperBound)
    }

    // MARK: - Диспетчеризация маршрутов

    private func dispatch(_ req: HTTPRequest, body: Data) {
        let route = HTTPRouter.resolve(path: req.path)
        let token = req.headers["x-zver-token"]

        switch route {
        case .pair:
            // Единственный маршрут без авторизации (выдаёт токен).
            guard req.method == "POST" else { return sendStatusOnly(405, reason: "Method Not Allowed") }
            handlePair(body: body)

        case .manifest:
            guard authorize(token) else { return sendUnauthorized() }
            guard req.method == "GET" else { return sendStatusOnly(405, reason: "Method Not Allowed") }
            handleManifest()

        case let .album(id, fileName):
            guard authorize(token) else { return sendUnauthorized() }
            guard req.method == "GET" else { return sendStatusOnly(405, reason: "Method Not Allowed") }
            handleFile(albumId: id, fileName: fileName, headers: req.headers)

        case .confirm:
            guard authorize(token) else { return sendUnauthorized() }
            guard req.method == "POST" else { return sendStatusOnly(405, reason: "Method Not Allowed") }
            handleConfirm(body: body)

        case .notFound:
            send(head: .notFound(), body: nil)
        }
    }

    private func authorize(_ token: String?) -> Bool {
        state.isAuthorized(token: token)
    }

    // MARK: - Обработчики маршрутов

    /// `POST /pair { code }` → `{ token }` (только в открытом окне pairing).
    private func handlePair(body: Data) {
        guard let pairRequest = try? JSONDecoder().decode(PairRequest.self, from: body),
              let token = state.tryPair(code: pairRequest.code) else {
            // Неверный код / закрытое окно — не раскрываем причину (401).
            sendUnauthorized()
            return
        }
        guard let payload = try? JSONEncoder().encode(PairResponse(token: token)) else {
            sendStatusOnly(500, reason: "Internal Server Error")
            return
        }
        sendJSON(payload)
    }

    /// `GET /manifest` → JSON текущего манифеста очереди.
    private func handleManifest() {
        let manifest = state.currentSnapshot().manifest
        guard let payload = try? JSONEncoder().encode(manifest) else {
            sendStatusOnly(500, reason: "Internal Server Error")
            return
        }
        sendJSON(payload)
    }

    /// `POST /confirm { albumId }` → 200. Подтверждение прыгает на `@MainActor`
    /// через `onConfirm` (внутри приложения). Сервер всегда отвечает 200
    /// (идемпотентность: confirm на уже снятый альбом — не ошибка).
    private func handleConfirm(body: Data) {
        struct ConfirmBody: Decodable { var albumId: String }
        guard let confirm = try? JSONDecoder().decode(ConfirmBody.self, from: body) else {
            sendStatusOnly(400, reason: "Bad Request")
            return
        }
        onConfirm(confirm.albumId)
        let head = HTTPResponseHead(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [("Content-Length", "0")]
        )
        send(head: head, body: nil)
    }

    /// `GET /album/<id>/<file>` → файл потоково с учётом `Range`/`If-Range`/`ETag`.
    private func handleFile(albumId: String, fileName: String, headers: [String: String]) {
        guard let served = state.currentSnapshot().file(albumId: albumId, fileName: fileName) else {
            send(head: .notFound(), body: nil)
            return
        }

        let fm = FileManager.default
        // Размер берём с диска (а не из снимка) — на случай рассинхрона.
        let fileSize: Int
        if let attrs = try? fm.attributesOfItem(atPath: served.url.path),
           let size = attrs[.size] as? NSNumber {
            fileSize = size.intValue
        } else {
            send(head: .notFound(), body: nil)
            return
        }

        let etag = served.sha256
        let contentType = Self.contentType(forFileName: fileName)

        // If-Range: если совпал с ETag — отдаём запрошенный диапазон (206);
        // иначе игнорируем Range и отдаём весь файл (200). Сравнение — по
        // значению ETag, как его шлёт клиент (с кавычками или без).
        let ifRange = headers["if-range"]
        let ifRangeMatches = Self.ifRangeMatches(ifRange, etag: etag)
        let rangeHeader = (ifRange == nil || ifRangeMatches) ? headers["range"] : nil

        let resolved = ByteRange.parse(header: rangeHeader, fileSize: fileSize)

        switch resolved {
        case .unsatisfiable:
            send(head: .rangeNotSatisfiable(totalSize: fileSize), body: nil)

        case .full:
            let head = HTTPResponseHead.ok(
                contentLength: fileSize,
                contentType: contentType,
                etag: etag
            )
            streamFile(served.url, head: head, start: 0, length: fileSize)

        case let .partial(start, end):
            let length = end - start + 1
            let head = HTTPResponseHead.partialContent(
                start: start,
                end: end,
                totalSize: fileSize,
                contentType: contentType,
                etag: etag
            )
            streamFile(served.url, head: head, start: start, length: length)
        }
    }

    // MARK: - Потоковая отдача файла

    /// Шлёт «голову» ответа, затем стримит `length` байт файла начиная с `start`
    /// чанками по `chunkSize` через `FileHandle` (без загрузки в память).
    private func streamFile(_ url: URL, head: HTTPResponseHead, start: Int, length: Int) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
            if start > 0 {
                try handle.seek(toOffset: UInt64(start))
            }
        } catch {
            send(head: .notFound(), body: nil)
            return
        }

        let headData = Data(head.serialized().utf8)
        connection.send(content: headData, completion: .contentProcessed { @Sendable [weak self] error in
            guard let self else { try? handle.close(); return }
            if error != nil {
                try? handle.close()
                self.close()
                return
            }
            self.streamNextChunk(handle: handle, remaining: length)
        })
    }

    /// Рекурсивно шлёт следующий чанк тела, пока не отдадим все `remaining` байт.
    private func streamNextChunk(handle: FileHandle, remaining: Int) {
        guard remaining > 0 else {
            try? handle.close()
            close()
            return
        }
        let take = min(chunkSize, remaining)
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: take) ?? Data()
        } catch {
            try? handle.close()
            close()
            return
        }
        guard !chunk.isEmpty else {
            // Файл оказался короче ожидаемого — завершаем (клиент сверит sha).
            try? handle.close()
            close()
            return
        }
        let nextRemaining = remaining - chunk.count
        connection.send(content: chunk, completion: .contentProcessed { @Sendable [weak self] error in
            guard let self else { try? handle.close(); return }
            if error != nil {
                try? handle.close()
                self.close()
                return
            }
            self.streamNextChunk(handle: handle, remaining: nextRemaining)
        })
    }

    // MARK: - Короткие ответы

    private func sendJSON(_ payload: Data) {
        let head = HTTPResponseHead(
            statusCode: 200,
            reasonPhrase: "OK",
            headers: [
                ("Content-Type", "application/json; charset=utf-8"),
                ("Content-Length", String(payload.count))
            ]
        )
        send(head: head, body: payload)
    }

    private func sendUnauthorized() {
        let head = HTTPResponseHead(
            statusCode: 401,
            reasonPhrase: "Unauthorized",
            headers: [("Content-Length", "0")]
        )
        send(head: head, body: nil)
    }

    private func sendStatusOnly(_ code: Int, reason: String) {
        let head = HTTPResponseHead(
            statusCode: code,
            reasonPhrase: reason,
            headers: [("Content-Length", "0")]
        )
        send(head: head, body: nil)
    }

    /// Шлёт голову + (опционально) тело и закрывает соединение.
    private func send(head: HTTPResponseHead, body: Data?) {
        var data = Data(head.serialized().utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { @Sendable [weak self] _ in
            self?.close()
        })
    }

    /// Закрывает соединение ровно один раз.
    private func close() {
        lock.lock()
        finished = true
        lock.unlock()
        connection.cancel()
    }

    // MARK: - MIME

    /// MIME-тип по расширению имени файла (хватает для аудио/обложек раздачи).
    private static func contentType(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "flac": return "audio/flac"
        case "alac", "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aiff", "aif": return "audio/aiff"
        case "mp3": return "audio/mpeg"
        case "dsf": return "audio/x-dsf"
        case "dff": return "audio/x-dff"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }

    /// Сравнивает значение `If-Range` с ETag файла (с учётом кавычек).
    private static func ifRangeMatches(_ ifRange: String?, etag: String) -> Bool {
        guard let ifRange else { return false }
        let unquoted = ifRange.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return unquoted == etag
    }
}
