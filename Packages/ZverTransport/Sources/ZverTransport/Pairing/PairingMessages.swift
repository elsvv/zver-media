import Foundation

/// Запрос на сопряжение: клиент (iPhone) шлёт введённый пользователем 6-значный
/// код хосту (Mac). Тело `POST /pair`.
public struct PairRequest: Codable, Equatable, Sendable {
    /// 6-значный код, показанный на Маке в окне pairing. Хранится строкой —
    /// ведущие нули значимы.
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

/// Ответ на успешное сопряжение: хост выдаёт одноразовый токен сессии. Тело
/// ответа `POST /pair`. Дальше клиент носит его в заголовке `X-Zver-Token`.
public struct PairResponse: Codable, Equatable, Sendable {
    /// Секретный токен доступа (например, 256-битный hex). Клиент кладёт его в
    /// `KeyStore` под сервисом-именем Мака.
    public var token: String

    public init(token: String) {
        self.token = token
    }
}
