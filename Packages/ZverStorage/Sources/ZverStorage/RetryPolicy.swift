import Foundation

/// Политика повторов для облачных передач: классификация ошибок и детерминированный
/// exponential backoff с учётом серверного `Retry-After`.
///
/// Чистая, без сети и часов — крутится поверх ``RemoteError`` из ``RemoteStore``
/// и используется планировщиком очереди (S4-4) и адаптером ``RemoteStore`` для
/// решения «повторять ли и через сколько». Backoff намеренно БЕЗ random jitter:
/// личное приложение с ≤2 параллельными передачами, а детерминизм даёт точные
/// тесты и предсказуемое поведение при отладке.
public struct RetryPolicy: Sendable, Equatable {
    /// Максимальное число попыток (включая первую). Дефолт — 5.
    public let maxAttempts: Int
    /// Базовая задержка экспоненты в секундах (множитель для `2^(attempt-1)`). Дефолт — 1.
    public let baseDelay: TimeInterval
    /// Верхний кламп экспоненты в секундах. Дефолт — 60. Явный серверный
    /// `Retry-After` может превышать этот кламп (директива сервера приоритетна).
    public let maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 60) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Классифицирует ошибку как ретраябельную (`true`) или фатальную (`false`).
    ///
    /// Ретраябельны временные сбои: `rateLimited` (429), `locked` (423), `server`
    /// (5xx) и `transport` (нет сети/таймаут/обрыв). Фатальны ошибки, повтор которых
    /// бессмыслен без вмешательства: `unauthorized` (перелогин), `notFound`,
    /// `conflict`, `insufficientStorage` (показать пользователю), `badResponse`.
    public func isRetryable(_ error: RemoteError) -> Bool {
        switch error {
        case .rateLimited, .locked, .server, .transport:
            return true
        case .unauthorized, .notFound, .conflict, .insufficientStorage, .badResponse:
            return false
        }
    }

    /// Вычисляет задержку перед попыткой номер `attempt` (нумерация с 1).
    ///
    /// База — `min(maxDelay, baseDelay * 2^(attempt-1))`: 1, 2, 4, 8, 16, … с
    /// клампом на `maxDelay`. Если сервер прислал `retryAfter`, берётся
    /// `max(экспонента, retryAfter)` — серверная директива перебивает короткую
    /// экспоненту, но НИКОГДА не уменьшает её (и может превысить `maxDelay`, т.к.
    /// явная просьба сервера приоритетнее нашего клампа). `attempt < 1` трактуется
    /// как первая попытка.
    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        let raw = baseDelay * pow(2, TimeInterval(exponent))
        let clamped = min(maxDelay, raw)
        guard let retryAfter else {
            return clamped
        }
        return max(clamped, retryAfter)
    }

    /// Стоит ли делать попытку номер `attempt` (нумерация с 1).
    ///
    /// `true`, пока `1 <= attempt <= maxAttempts`. Вызывающий проверяет это ПЕРЕД
    /// повтором: исчерпав `maxAttempts`, переводит элемент в `failed`.
    public func shouldRetry(attempt: Int) -> Bool {
        attempt >= 1 && attempt <= maxAttempts
    }
}
