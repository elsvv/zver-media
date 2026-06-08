import Foundation

/// Маппинг HTTP-ответа Яндекс.Диска (статус + тело + заголовки) в ``RemoteError``.
///
/// Классификация определяется СТАТУСОМ (тело — лишь диагностика, не влияет на
/// класс). `RetryPolicy` (S4-3) дальше делит классы на ретраябельные/фатальные.
/// Заголовок `Retry-After` (для 429) парсится в секунды: поддерживаются обе формы
/// RFC 7231 — целые секунды и HTTP-дата (RFC 1123), дельта до которой клампится в `0`.
public enum YandexError {
    /// Преобразует не-2xx ответ в ``RemoteError``.
    ///
    /// - Parameters:
    ///   - status: HTTP-статус-код ответа.
    ///   - data: тело ответа (может нести `{message,description,error}` — не влияет на класс).
    ///   - headers: заголовки ответа (для `Retry-After` на 429).
    public static func from(status: Int, data: Data, headers: [String: String]) -> RemoteError {
        switch status {
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 409:
            return .conflict
        case 423:
            return .locked
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: headers))
        case 507:
            return .insufficientStorage
        case 500...599:
            return .server(status: status)
        default:
            // 403 и любые прочие не-2xx, не имеющие отдельного кейса, — фатальный badResponse.
            return .badResponse
        }
    }

    // MARK: - Retry-After

    /// Извлекает задержку из заголовка `Retry-After` в секундах.
    ///
    /// Регистр имени заголовка игнорируется. Значение — либо целые секунды
    /// (`"30"`), либо HTTP-дата RFC 1123 (`"Wed, 21 Oct 2026 07:28:00 GMT"`), для
    /// которой считается дельта от текущего момента (отрицательная → `0`).
    /// Нераспознанное значение → `nil`.
    static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let raw = headerValue("Retry-After", in: headers) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // Форма 1: целые секунды.
        if let seconds = TimeInterval(trimmed), seconds >= 0 {
            return seconds
        }

        // Форма 2: HTTP-дата (RFC 1123).
        if let date = httpDate(trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }

        return nil
    }

    /// Регистронезависимый поиск заголовка по имени.
    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        if let direct = headers[name] {
            return direct
        }
        let lower = name.lowercased()
        for (key, value) in headers where key.lowercased() == lower {
            return value
        }
        return nil
    }

    /// Парсер HTTP-даты в формате RFC 1123 (единственный обязательный по спеке вид
    /// для `Retry-After`). Возвращает `nil` для неразбираемой строки.
    private static func httpDate(_ string: String) -> Date? {
        Self.rfc1123Formatter.date(from: string)
    }

    /// Кэшированный форматтер RFC 1123 в GMT с POSIX-локалью (стабильный парсинг).
    private static let rfc1123Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
}
