import Testing
import Foundation
@testable import ZverTransport

@Suite struct HTTPRequestParserTests {
    /// Удобный helper: байты из строки в latin-совместимой кодировке (HTTP-заголовки ASCII).
    private func bytes(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Цельный запрос за один feed

    @Test func parsesSimpleGetInOneFeed() throws {
        var parser = HTTPRequestParser()
        let raw = "GET /manifest HTTP/1.1\r\nHost: zver.local\r\n\r\n"
        let result = parser.feed(bytes(raw))
        guard case let .request(request) = result else {
            Issue.record("ожидали .request, получили \(result)")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/manifest")
        #expect(request.headers["host"] == "zver.local")
        #expect(request.contentLength == 0)
    }

    // MARK: - Сборка из нескольких TCP-сегментов

    @Test func reassemblesRequestFromMultipleSegments() throws {
        var parser = HTTPRequestParser()

        // Запрос приходит четырьмя кусками — как TCP-сегменты.
        let segments = [
            "GET /album/Radio",
            "head%20-%20In%20Rainbows/01.flac HTTP/1.1\r\n",
            "Host: zver.local\r\nRange: bytes=0-10",
            "23\r\n\r\n"
        ]

        var finalResult: HTTPRequestParser.ParseResult = .needMore
        for (index, segment) in segments.enumerated() {
            finalResult = parser.feed(bytes(segment))
            if index < segments.count - 1 {
                // Пока CRLFCRLF не пришёл — needMore.
                #expect({ if case .needMore = finalResult { return true } else { return false } }())
            }
        }

        guard case let .request(request) = finalResult else {
            Issue.record("ожидали .request после последнего сегмента, получили \(finalResult)")
            return
        }
        #expect(request.method == "GET")
        #expect(request.path == "/album/Radiohead%20-%20In%20Rainbows/01.flac")
        #expect(request.headers["host"] == "zver.local")
        #expect(request.headers["range"] == "bytes=0-1023")
    }

    // MARK: - Регистронезависимость имён заголовков

    @Test func headerNamesAreCaseInsensitive() throws {
        var parser = HTTPRequestParser()
        let raw = "GET /manifest HTTP/1.1\r\nX-Zver-Token: ABC123\r\nCONTENT-TYPE: application/json\r\nRaNgE: bytes=5-\r\n\r\n"
        guard case let .request(request) = parser.feed(bytes(raw)) else {
            Issue.record("ожидали .request")
            return
        }
        // Имена нормализованы к нижнему регистру; значения сохранены как есть.
        #expect(request.headers["x-zver-token"] == "ABC123")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.headers["range"] == "bytes=5-")
        // Доступ по нижнему регистру; верхний регистр ключа в словаре отсутствует.
        #expect(request.headers["X-Zver-Token"] == nil)
    }

    // MARK: - Пробелы вокруг значения заголовка обрезаются

    @Test func headerValueWhitespaceIsTrimmed() throws {
        var parser = HTTPRequestParser()
        let raw = "GET /manifest HTTP/1.1\r\nHost:    zver.local   \r\n\r\n"
        guard case let .request(request) = parser.feed(bytes(raw)) else {
            Issue.record("ожидали .request")
            return
        }
        #expect(request.headers["host"] == "zver.local")
    }

    // MARK: - Content-Length для POST

    @Test func reportsContentLengthForPost() throws {
        var parser = HTTPRequestParser()
        let raw = "POST /pair HTTP/1.1\r\nContent-Length: 17\r\nContent-Type: application/json\r\n\r\n"
        guard case let .request(request) = parser.feed(bytes(raw)) else {
            Issue.record("ожидали .request")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/pair")
        // Тело докачивается отдельно — парсер отдаёт длину вызывающему.
        #expect(request.contentLength == 17)
    }

    @Test func contentLengthDefaultsToZeroWhenAbsent() throws {
        var parser = HTTPRequestParser()
        let raw = "POST /confirm HTTP/1.1\r\nHost: zver.local\r\n\r\n"
        guard case let .request(request) = parser.feed(bytes(raw)) else {
            Issue.record("ожидали .request")
            return
        }
        #expect(request.contentLength == 0)
    }

    // MARK: - Неполные заголовки → needMore

    @Test func incompleteHeadersReturnNeedMore() {
        var parser = HTTPRequestParser()
        let result = parser.feed(bytes("GET /manifest HTTP/1.1\r\nHost: zver.local\r\n"))
        #expect({ if case .needMore = result { return true } else { return false } }())
    }

    @Test func emptyFeedReturnsNeedMore() {
        var parser = HTTPRequestParser()
        let result = parser.feed(Data())
        #expect({ if case .needMore = result { return true } else { return false } }())
    }

    // MARK: - Заголовок без двоеточия игнорируется, парс не падает

    @Test func malformedHeaderLineIsSkipped() throws {
        var parser = HTTPRequestParser()
        let raw = "GET /manifest HTTP/1.1\r\ngarbage-without-colon\r\nHost: zver.local\r\n\r\n"
        guard case let .request(request) = parser.feed(bytes(raw)) else {
            Issue.record("ожидали .request несмотря на битую строку")
            return
        }
        #expect(request.headers["host"] == "zver.local")
        #expect(request.method == "GET")
    }

    // MARK: - Значение заголовка с двоеточием внутри (например время)

    @Test func headerValueCanContainColons() throws {
        var parser = HTTPRequestParser()
        let raw = "GET /manifest HTTP/1.1\r\nIf-Range: \"abc:def:123\"\r\n\r\n"
        guard case let .request(request) = parser.feed(bytes(raw)) else {
            Issue.record("ожидали .request")
            return
        }
        // Разбивка только по первому двоеточию.
        #expect(request.headers["if-range"] == "\"abc:def:123\"")
    }

    // MARK: - Завершённый, но битый запрос → .invalid (не вечный .needMore)

    @Test func completeButMalformedRequestLineIsInvalid() {
        var parser = HTTPRequestParser()
        // Терминатор есть, но request-line из одного токена — это не «нужно ещё
        // байт», а битый запрос: должен прийти .invalid (сервер ответит 400).
        let result = parser.feed(bytes("PING\r\n\r\n"))
        #expect({ if case .invalid = result { return true } else { return false } }())
    }

    @Test func emptyRequestLineIsInvalid() {
        var parser = HTTPRequestParser()
        let result = parser.feed(bytes("\r\n\r\n"))
        #expect({ if case .invalid = result { return true } else { return false } }())
    }

    @Test func partialHeadersStillNeedMoreNotInvalid() {
        var parser = HTTPRequestParser()
        // Нет терминатора — по-прежнему .needMore (не путаем с битым).
        let result = parser.feed(bytes("GET /manifest HTTP/1.1\r\nHost: z"))
        #expect({ if case .needMore = result { return true } else { return false } }())
    }
}
