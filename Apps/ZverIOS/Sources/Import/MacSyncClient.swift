import Foundation
import Network
import ZverTransport

/// Тонкий сетевой клиент к файловому серверу Мака поверх `NWConnection`.
///
/// Браузер (`NWServiceBrowser`) отдаёт только имя Bonjour-сервиса — host/port не
/// резолвятся заранее. Поэтому коннектимся прямо к Bonjour-endpoint
/// `NWEndpoint.service(name:type:domain:)`: система сама резолвит адрес при
/// установке соединения. На этом этапе (S3-10) нужны лишь два запроса — `POST
/// /pair` и `GET /manifest`; полноценный докачиваемый трансфер файлов — S3-11.
///
/// Рантайм-сетевой объект (`NWConnection`) живёт в app-таргете — это
/// непокрываемый тестами адаптер (лессон прошлых этапов). Замыкания, передаваемые
/// в `NWConnection` и вызываемые на сетевой очереди, помечены `@Sendable`; переход
/// в UI делает вызывающая `@MainActor`-модель через `Task { @MainActor in … }`.
///
/// `@unchecked Sendable` оправдан: всё мутабельное состояние живёт на приватной
/// последовательной очереди `queue`.
final class MacSyncClient: @unchecked Sendable {
    /// Сетевые ошибки клиента — диагностируемые причины сбоя запроса.
    enum ClientError: Error, Sendable {
        /// Соединение оборвалось/не установилось.
        case connectionFailed
        /// Ответ сервера не разобрался как HTTP (нет статус-строки/тела).
        case malformedResponse
        /// Статус ответа не 2xx (с кодом для диагностики).
        case httpStatus(Int)
        /// Тело ответа не декодируется в ожидаемый тип.
        case decodingFailed
        /// Таймаут запроса.
        case timeout
    }

    /// Имя Bonjour-сервиса Мака (как пришло от браузера).
    private let serviceName: String
    private let queue = DispatchQueue(label: "dev.zver.mac-sync-client")
    /// Предельное время одного запроса. Защита от зависших соединений.
    private let requestTimeout: TimeInterval

    init(serviceName: String, requestTimeout: TimeInterval = 15) {
        self.serviceName = serviceName
        self.requestTimeout = requestTimeout
    }

    // MARK: - Высокоуровневые запросы протокола

    /// `POST /pair { code }` → `PairResponse { token }`.
    ///
    /// Выполняется в окне pairing на Маке: при верном коде сервер возвращает
    /// одноразовый токен сессии, который дальше носится в `X-Zver-Token`.
    func pair(code: String) async throws -> PairResponse {
        let body = try JSONEncoder().encode(PairRequest(code: code))
        let data = try await send(
            method: "POST",
            path: "/pair",
            token: nil,
            body: body
        )
        guard let response = try? JSONDecoder().decode(PairResponse.self, from: data) else {
            throw ClientError.decodingFailed
        }
        return response
    }

    /// `GET /manifest` с авторизацией `X-Zver-Token` → `SyncManifest`.
    ///
    /// Манифест описывает исходящую очередь Мака (альбомы и треки с sha256).
    /// Здесь он нужен только для предпросмотра; скачивание файлов — S3-11.
    func fetchManifest(token: String) async throws -> SyncManifest {
        let data = try await send(
            method: "GET",
            path: "/manifest",
            token: token,
            body: nil
        )
        guard let manifest = try? JSONDecoder().decode(SyncManifest.self, from: data) else {
            throw ClientError.decodingFailed
        }
        return manifest
    }

    // MARK: - Сырой HTTP поверх NWConnection

    /// Отправляет один HTTP/1.1-запрос и возвращает тело ответа (только при 2xx).
    ///
    /// Соединение одноразовое (`Connection: close`): открываем, шлём запрос,
    /// читаем до EOF, разбираем статус и тело. Этого достаточно для коротких
    /// JSON-ответов протокола; потоковую докачку файлов сделает S3-11.
    private func send(method: String,
                      path: String,
                      token: String?,
                      body: Data?) async throws -> Data {
        let request = Self.buildRequest(
            method: method,
            path: path,
            host: serviceName,
            token: token,
            body: body
        )

        let endpoint = NWEndpoint.service(
            name: serviceName,
            type: zverServiceType,
            domain: "local.",
            interface: nil
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        let raw = try await withRequestTimeout {
            try await Self.exchange(
                connection: connection,
                request: request,
                queue: self.queue
            )
        }

        let (status, responseBody) = try Self.parseResponse(raw)
        guard (200...299).contains(status) else {
            throw ClientError.httpStatus(status)
        }
        return responseBody
    }

    /// Оборачивает запрос таймаутом: первый завершившийся из двух гонок
    /// (обмен или сон) определяет исход, второй отменяется.
    private func withRequestTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = requestTimeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ClientError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ClientError.connectionFailed
            }
            return result
        }
    }

    // MARK: - Чистые помощники (сборка/разбор HTTP)

    /// Собирает байты HTTP/1.1-запроса. `@Sendable`-чистая функция — без сети.
    static func buildRequest(method: String,
                             path: String,
                             host: String,
                             token: String?,
                             body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: \(host)\r\n"
        head += "Connection: close\r\n"
        if let token {
            head += "X-Zver-Token: \(token)\r\n"
        }
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"

        var data = Data(head.utf8)
        if let body {
            data.append(body)
        }
        return data
    }

    /// Разбирает сырой ответ на статус-код и тело. `@Sendable`-чистая функция.
    ///
    /// Минимальный разбор для коротких JSON-ответов: находит границу
    /// заголовков (`\r\n\r\n`), вытаскивает код из статус-строки, всё после
    /// границы — тело. Для GET/POST протокола этого достаточно.
    static func parseResponse(_ raw: Data) throws -> (status: Int, body: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw ClientError.malformedResponse
        }
        let headerData = raw.subdata(in: raw.startIndex..<range.lowerBound)
        let body = raw.subdata(in: range.upperBound..<raw.endIndex)

        guard let header = String(data: headerData, encoding: .utf8),
              let statusLine = header.split(separator: "\r\n").first
        else {
            throw ClientError.malformedResponse
        }

        // Статус-строка: "HTTP/1.1 200 OK" — код это второй компонент.
        let components = statusLine.split(separator: " ")
        guard components.count >= 2, let status = Int(components[1]) else {
            throw ClientError.malformedResponse
        }
        return (status, body)
    }

    /// Открывает соединение, шлёт запрос, читает до EOF. Замыкания `NWConnection`
    /// — `@Sendable`, на сетевой очереди. Чистый async-фасад поверх колбэков.
    private static func exchange(connection: NWConnection,
                                 request: Data,
                                 queue: DispatchQueue) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            // Гонка отмены/двойного резюма исключена флагом под актором-боксом:
            // continuation резюмится ровно один раз. Box потокобезопасен через
            // ту же сетевую очередь, на которую завязаны все колбэки соединения.
            let box = ContinuationBox(continuation: continuation, connection: connection)

            connection.stateUpdateHandler = { @Sendable state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { @Sendable error in
                        if let error {
                            box.fail(.connectionFailed, underlying: error)
                            return
                        }
                        Self.receiveAll(connection: connection, accumulated: Data(), box: box)
                    })
                case let .failed(error):
                    box.fail(.connectionFailed, underlying: error)
                case .cancelled:
                    box.failIfPending(.connectionFailed)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    /// Рекурсивно дочитывает тело до EOF (`isComplete`), затем резюмит box.
    private static func receiveAll(connection: NWConnection,
                                   accumulated: Data,
                                   box: ContinuationBox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { @Sendable content, _, isComplete, error in
            var data = accumulated
            if let content { data.append(content) }

            if let error {
                box.fail(.connectionFailed, underlying: error)
                return
            }
            if isComplete {
                box.succeed(data)
                return
            }
            Self.receiveAll(connection: connection, accumulated: data, box: box)
        }
    }
}

/// Однократно-резюмируемый бокс над `CheckedContinuation`: гарантирует ровно один
/// resume даже при гонке колбэков `NWConnection` на сетевой очереди. Закрывает
/// соединение при завершении. `@unchecked Sendable` оправдан: флаг под `NSLock`.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Data, Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func succeed(_ data: Data) {
        resume { $0.resume(returning: data) }
    }

    func fail(_ error: MacSyncClient.ClientError, underlying: Error? = nil) {
        resume { $0.resume(throwing: error) }
    }

    /// Резюмит ошибкой только если continuation ещё жив (для .cancelled, когда
    /// успех/провал уже могли отработать).
    func failIfPending(_ error: MacSyncClient.ClientError) {
        resume { $0.resume(throwing: error) }
    }

    private func resume(_ action: (CheckedContinuation<Data, Error>) -> Void) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        action(continuation)
    }
}
