import Foundation

/// Мок `URLProtocol` для перехвата запросов ``OpenAICompatibleClient`` без сети.
///
/// Регистрируется в `URLSessionConfiguration.protocolClasses`; отдаёт заранее
/// заданный ответ (статус + тело) ЛИБО транспортную ошибку, и запоминает тело
/// последнего запроса (для проверки сериализации промпта). Доступ к общему
/// состоянию под `NSLock` — `URLSession` дёргает протокол с фоновых очередей.
final class MockURLProtocol: URLProtocol {
    /// Что вернуть на следующий запрос.
    struct Stub {
        var statusCode: Int = 200
        var body: Data = Data()
        var error: (any Error)?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub = Stub()
    nonisolated(unsafe) private static var _lastRequestBody: Data?
    nonisolated(unsafe) private static var _lastRequestURL: URL?
    nonisolated(unsafe) private static var _lastRequestHeaders: [String: String]?

    /// Задать ответ и сбросить запомненное про предыдущий запрос.
    static func setStub(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        _stub = stub
        _lastRequestBody = nil
        _lastRequestURL = nil
        _lastRequestHeaders = nil
    }

    /// Тело последнего перехваченного запроса (декодированное из body-stream).
    static func lastRequestBody() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestBody
    }

    /// URL последнего перехваченного запроса (для проверки endpoint-пути).
    static func lastRequestURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestURL
    }

    /// Заголовки последнего перехваченного запроса (для проверки авторизации).
    static func lastRequestHeaders() -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestHeaders
    }

    private static func currentStub() -> Stub {
        lock.lock(); defer { lock.unlock() }
        return _stub
    }

    private static func recordRequest(body: Data?, url: URL?, headers: [String: String]?) {
        lock.lock(); defer { lock.unlock() }
        _lastRequestBody = body
        _lastRequestURL = url
        _lastRequestHeaders = headers
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.recordRequest(
            body: Self.bodyData(from: request),
            url: request.url,
            headers: request.allHTTPHeaderFields
        )
        let stub = MockURLProtocol.currentStub()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession перекладывает `httpBody` в `httpBodyStream` к моменту перехвата —
    /// достаём тело из потока, если прямого body нет.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
