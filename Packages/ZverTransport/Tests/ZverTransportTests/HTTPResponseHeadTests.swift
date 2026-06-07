import Testing
import Foundation
@testable import ZverTransport

@Suite struct HTTPResponseHeadTests {
    /// Разбирает собранную голову ответа на статус-строку и словарь заголовков
    /// (имена к нижнему регистру) для устойчивых проверок без зависимости от порядка.
    private func dissect(_ head: String) -> (statusLine: String, headers: [String: String]) {
        // Голова заканчивается пустой строкой (CRLFCRLF).
        #expect(head.hasSuffix("\r\n\r\n"))
        let lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.first ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return (statusLine, headers)
    }

    // MARK: - 200 OK

    @Test func ok200WithContentLengthAndType() {
        let head = HTTPResponseHead.ok(
            contentLength: 12345,
            contentType: "audio/flac",
            etag: "abc123"
        ).serialized()
        let (status, headers) = dissect(head)
        #expect(status == "HTTP/1.1 200 OK")
        #expect(headers["content-length"] == "12345")
        #expect(headers["content-type"] == "audio/flac")
        #expect(headers["accept-ranges"] == "bytes")
        #expect(headers["etag"] == "\"abc123\"")
    }

    @Test func ok200WithoutEtag() {
        let head = HTTPResponseHead.ok(
            contentLength: 50,
            contentType: "application/json",
            etag: nil
        ).serialized()
        let (status, headers) = dissect(head)
        #expect(status == "HTTP/1.1 200 OK")
        #expect(headers["content-length"] == "50")
        #expect(headers["content-type"] == "application/json")
        #expect(headers["etag"] == nil)
    }

    // MARK: - 206 Partial Content

    @Test func partial206WithContentRange() {
        let head = HTTPResponseHead.partialContent(
            start: 100,
            end: 199,
            totalSize: 1000,
            contentType: "audio/flac",
            etag: "deadbeef"
        ).serialized()
        let (status, headers) = dissect(head)
        #expect(status == "HTTP/1.1 206 Partial Content")
        // Content-Length диапазона = end - start + 1.
        #expect(headers["content-length"] == "100")
        #expect(headers["content-range"] == "bytes 100-199/1000")
        #expect(headers["accept-ranges"] == "bytes")
        #expect(headers["content-type"] == "audio/flac")
        #expect(headers["etag"] == "\"deadbeef\"")
    }

    // MARK: - 404 Not Found

    @Test func notFound404() {
        let head = HTTPResponseHead.notFound().serialized()
        let (status, headers) = dissect(head)
        #expect(status == "HTTP/1.1 404 Not Found")
        // Пустое тело.
        #expect(headers["content-length"] == "0")
    }

    // MARK: - 416 Range Not Satisfiable

    @Test func rangeNotSatisfiable416CarriesTotalSize() {
        let head = HTTPResponseHead.rangeNotSatisfiable(totalSize: 1000).serialized()
        let (status, headers) = dissect(head)
        #expect(status == "HTTP/1.1 416 Range Not Satisfiable")
        // Должен сообщить актуальный размер: "bytes */<size>".
        #expect(headers["content-range"] == "bytes */1000")
        #expect(headers["content-length"] == "0")
    }

    // MARK: - Структура головы

    @Test func headEndsWithBlankLine() {
        let head = HTTPResponseHead.ok(contentLength: 0, contentType: "text/plain", etag: nil).serialized()
        #expect(head.hasSuffix("\r\n\r\n"))
        // Ровно одна пустая строка-разделитель в конце (не две).
        #expect(!head.hasSuffix("\r\n\r\n\r\n"))
    }

    @Test func statusLineComesFirst() {
        let head = HTTPResponseHead.ok(contentLength: 0, contentType: "text/plain", etag: nil).serialized()
        #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
    }
}
