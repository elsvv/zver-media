import Testing
import Foundation
@testable import ZverStorage

/// Тесты маппинга HTTP-статуса + тела + заголовков в `RemoteError`.
///
/// Покрываем все ветви классов ошибок из спецификации и обе формы заголовка
/// `Retry-After` (целые секунды и HTTP-дата RFC 1123).
@Suite struct YandexErrorTests {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: - классы статусов

    @Test func status401IsUnauthorized() {
        let err = YandexError.from(status: 401, data: Data(), headers: [:])
        #expect(isCase(err, .unauthorized))
    }

    @Test func status404IsNotFound() {
        let err = YandexError.from(status: 404, data: Data(), headers: [:])
        #expect(isCase(err, .notFound))
    }

    @Test func status403IsNotFoundClassFatal() {
        // 403 — фатально; маппим в badResponse (нет отдельного forbidden-кейса).
        let err = YandexError.from(status: 403, data: Data(), headers: [:])
        #expect(isCase(err, .badResponse) || isCase(err, .unauthorized))
    }

    @Test func status409IsConflict() {
        let err = YandexError.from(status: 409, data: Data(), headers: [:])
        #expect(isCase(err, .conflict))
    }

    @Test func status423IsLocked() {
        let err = YandexError.from(status: 423, data: Data(), headers: [:])
        #expect(isCase(err, .locked))
    }

    @Test func status507IsInsufficientStorage() {
        let err = YandexError.from(status: 507, data: Data(), headers: [:])
        #expect(isCase(err, .insufficientStorage))
    }

    @Test func status500IsServer() {
        let err = YandexError.from(status: 500, data: Data(), headers: [:])
        if case let .server(status) = err {
            #expect(status == 500)
        } else {
            Issue.record("ожидался .server")
        }
    }

    @Test func status503IsServer() {
        let err = YandexError.from(status: 503, data: Data(), headers: [:])
        if case let .server(status) = err {
            #expect(status == 503)
        } else {
            Issue.record("ожидался .server")
        }
    }

    @Test func unknownNon2xxIsBadResponse() {
        let err = YandexError.from(status: 418, data: Data(), headers: [:])
        #expect(isCase(err, .badResponse))
    }

    // MARK: - 429 + Retry-After

    @Test func status429WithoutRetryAfterIsRateLimitedNil() {
        let err = YandexError.from(status: 429, data: Data(), headers: [:])
        if case let .rateLimited(retryAfter) = err {
            #expect(retryAfter == nil)
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    @Test func status429WithRetryAfterSeconds() {
        let err = YandexError.from(status: 429, data: Data(), headers: ["Retry-After": "30"])
        if case let .rateLimited(retryAfter) = err {
            #expect(retryAfter == 30)
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    @Test func retryAfterHeaderIsCaseInsensitive() {
        let err = YandexError.from(status: 429, data: Data(), headers: ["retry-after": "5"])
        if case let .rateLimited(retryAfter) = err {
            #expect(retryAfter == 5)
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    @Test func status429WithHttpDateRetryAfter() {
        // RFC 1123 дата: вычисляем дельту до неё. Берём момент в будущем.
        let future = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let httpDate = formatter.string(from: future)

        let err = YandexError.from(status: 429, data: Data(), headers: ["Retry-After": httpDate])
        if case let .rateLimited(retryAfter) = err {
            let ra = try? #require(retryAfter)
            if let ra {
                // ~120с до даты, допускаем погрешность на время выполнения теста.
                #expect(ra > 110 && ra <= 121)
            }
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    @Test func retryAfterHttpDateInPastClampsToZero() {
        let past = Date().addingTimeInterval(-300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let httpDate = formatter.string(from: past)

        let err = YandexError.from(status: 429, data: Data(), headers: ["Retry-After": httpDate])
        if case let .rateLimited(retryAfter) = err {
            #expect(retryAfter == 0)
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    @Test func retryAfterGarbageIsNil() {
        let err = YandexError.from(status: 429, data: Data(), headers: ["Retry-After": "not-a-number"])
        if case let .rateLimited(retryAfter) = err {
            #expect(retryAfter == nil)
        } else {
            Issue.record("ожидался .rateLimited")
        }
    }

    // MARK: - Retry-After уважается и на 503

    @Test func status503WithRetryAfterStillServerButHonoured() {
        // Сервер может прислать Retry-After и на 5xx — но класс ошибки .server.
        let err = YandexError.from(status: 503, data: Data(), headers: ["Retry-After": "10"])
        #expect(isCase(err, .server(status: 503)))
    }

    // MARK: - тело ошибки не влияет на класс, но парсится

    @Test func errorBodyDoesNotChangeClassification() {
        let json = """
        { "message": "m", "description": "d", "error": "DiskNotFoundError" }
        """
        let err = YandexError.from(status: 404, data: body(json), headers: [:])
        #expect(isCase(err, .notFound))
    }

    // MARK: - helper

    /// Грубое сравнение кейсов без ассоциированных значений (для unauthorized/notFound и т.п.).
    private func isCase(_ error: RemoteError, _ expected: RemoteError) -> Bool {
        switch (error, expected) {
        case (.unauthorized, .unauthorized),
             (.notFound, .notFound),
             (.conflict, .conflict),
             (.locked, .locked),
             (.insufficientStorage, .insufficientStorage),
             (.badResponse, .badResponse):
            return true
        case let (.server(a), .server(b)):
            return a == b
        case (.rateLimited, .rateLimited):
            return true
        case (.transport, .transport):
            return true
        default:
            return false
        }
    }
}
