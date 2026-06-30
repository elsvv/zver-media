import Foundation

/// Разобранный HTTP-запрос: только то, что нужно протоколу синка.
///
/// `headers` — имена нормализованы к нижнему регистру (HTTP-имена заголовков
/// регистронезависимы, RFC 7230 §3.2). `contentLength` извлечён из
/// `Content-Length` (0, если отсутствует) — тело для POST докачивается отдельно,
/// парсер заголовков его не ждёт.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var contentLength: Int

    public init(method: String, path: String, headers: [String: String], contentLength: Int) {
        self.method = method
        self.path = path
        self.headers = headers
        self.contentLength = contentLength
    }
}

/// Инкрементальный парсер HTTP-запроса поверх TCP.
///
/// Накапливает байты между вызовами `feed(_:)` и пытается разобрать заголовки,
/// как только встретит разделитель `CRLFCRLF`. Тело (для POST) намеренно НЕ
/// разбирается — его длина отдаётся вызывающему через `HTTPRequest.contentLength`,
/// а сами байты тела докачиваются отдельным каналом. Это `struct` с мутирующим
/// `feed` — состояние (накопленный буфер) живёт у вызывающего, без скрытой
/// разделяемой изменяемости.
public struct HTTPRequestParser: Sendable {
    /// Результат очередного `feed`.
    public enum ParseResult: Sendable {
        /// Заголовки ещё неполны (нет `CRLFCRLF`) — нужно скормить ещё байты.
        case needMore
        /// Заголовки полностью разобраны.
        case request(HTTPRequest)
        /// Терминатор `CRLFCRLF` пришёл, но request-line битый (нет метода/таргета) —
        /// это НЕ «нужно ещё байт». Сервер должен ответить 400 и закрыться, иначе
        /// соединение висит вечно в `.needMore`, держа обработчик.
        case invalid
    }

    /// Накопленный сырой поток заголовков.
    private var buffer = Data()

    /// Разделитель конца заголовков: `\r\n\r\n`.
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    public init() {}

    /// Скармливает очередной кусок байтов (TCP-сегмент) и пробует разобрать заголовки.
    ///
    /// Идемпотентно по смыслу: пока `CRLFCRLF` не пришёл — возвращает `.needMore`
    /// и копит. Как только разделитель есть — разбирает и возвращает `.request`.
    public mutating func feed(_ data: Data) -> ParseResult {
        buffer.append(data)

        guard let terminatorRange = buffer.range(of: Self.headerTerminator) else {
            return .needMore
        }

        let headerData = buffer[buffer.startIndex..<terminatorRange.lowerBound]
        guard let request = Self.parseHeaderBlock(headerData) else {
            // Терминатор есть, но блок не разобрался → запрос битый, не «неполный».
            return .invalid
        }
        return .request(request)
    }

    /// Разбирает блок заголовков (без завершающего `CRLFCRLF`) в `HTTPRequest`.
    /// Возвращает nil, если request-line отсутствует/битый.
    private static func parseHeaderBlock(_ data: Data) -> HTTPRequest? {
        // Заголовки — ASCII/latin1; декодируем устойчиво.
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        // Строки разделены CRLF; пустых в блоке заголовков (до терминатора) быть не должно.
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return nil
        }

        // request-line: METHOD SP request-target SP HTTP-version
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return nil
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            // Разбивка по ПЕРВОМУ двоеточию: значение может содержать ':' (например ETag/время).
            guard let colon = line.firstIndex(of: ":") else {
                // Битая строка заголовка без двоеточия — пропускаем, не падаем.
                continue
            }
            let name = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }

        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0

        return HTTPRequest(method: method, path: path, headers: headers, contentLength: contentLength)
    }
}
