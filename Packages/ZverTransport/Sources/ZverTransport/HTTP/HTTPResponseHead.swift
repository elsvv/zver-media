import Foundation

/// Чистый билдер «головы» HTTP-ответа (статус-строка + заголовки + завершающий
/// `CRLFCRLF`). Тело отправляется отдельно (потоково `FileHandle`), поэтому здесь —
/// только строковая сборка. Покрывает коды протокола синка: 200/206/404/416.
///
/// `Accept-Ranges: bytes` присутствует на успешных ответах файла, чтобы клиент
/// знал о поддержке докачки. `ETag` (= sha256 файла из манифеста) даёт корректный
/// `If-Range`-resume у `URLSession`.
public struct HTTPResponseHead: Equatable, Sendable {
    public var statusCode: Int
    public var reasonPhrase: String
    /// Упорядоченный список заголовков (имя, значение) — порядок сохраняется при
    /// сериализации, но логике клиента он безразличен.
    public var headers: [(name: String, value: String)]

    public init(statusCode: Int, reasonPhrase: String, headers: [(name: String, value: String)]) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
    }

    public static func == (lhs: HTTPResponseHead, rhs: HTTPResponseHead) -> Bool {
        lhs.statusCode == rhs.statusCode
            && lhs.reasonPhrase == rhs.reasonPhrase
            && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    /// Сериализует голову в строку: `HTTP/1.1 <code> <reason>\r\n<headers>\r\n\r\n`.
    public func serialized() -> String {
        var out = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        for header in headers {
            out += "\(header.name): \(header.value)\r\n"
        }
        out += "\r\n"
        return out
    }

    // MARK: - Конструкторы под коды протокола

    /// 200 OK с полным телом.
    public static func ok(contentLength: Int, contentType: String, etag: String?) -> HTTPResponseHead {
        var headers: [(name: String, value: String)] = [
            ("Content-Type", contentType),
            ("Content-Length", String(contentLength)),
            ("Accept-Ranges", "bytes")
        ]
        if let etag {
            headers.append(("ETag", quote(etag)))
        }
        return HTTPResponseHead(statusCode: 200, reasonPhrase: "OK", headers: headers)
    }

    /// 206 Partial Content для включительного диапазона `[start, end]` файла размера
    /// `totalSize`. `Content-Length` = длина диапазона, `Content-Range: bytes start-end/total`.
    public static func partialContent(start: Int,
                                      end: Int,
                                      totalSize: Int,
                                      contentType: String,
                                      etag: String?) -> HTTPResponseHead {
        let length = end - start + 1
        var headers: [(name: String, value: String)] = [
            ("Content-Type", contentType),
            ("Content-Length", String(length)),
            ("Accept-Ranges", "bytes"),
            ("Content-Range", "bytes \(start)-\(end)/\(totalSize)")
        ]
        if let etag {
            headers.append(("ETag", quote(etag)))
        }
        return HTTPResponseHead(statusCode: 206, reasonPhrase: "Partial Content", headers: headers)
    }

    /// 404 Not Found, пустое тело.
    public static func notFound() -> HTTPResponseHead {
        HTTPResponseHead(
            statusCode: 404,
            reasonPhrase: "Not Found",
            headers: [("Content-Length", "0")]
        )
    }

    /// 416 Range Not Satisfiable: сообщает актуальный размер через `Content-Range: bytes */<size>`.
    public static func rangeNotSatisfiable(totalSize: Int) -> HTTPResponseHead {
        HTTPResponseHead(
            statusCode: 416,
            reasonPhrase: "Range Not Satisfiable",
            headers: [
                ("Content-Range", "bytes */\(totalSize)"),
                ("Content-Length", "0")
            ]
        )
    }

    /// Оборачивает значение ETag в кавычки, если оно ещё не закавычено (RFC 7232 §2.3).
    private static func quote(_ value: String) -> String {
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return value
        }
        return "\"\(value)\""
    }
}
