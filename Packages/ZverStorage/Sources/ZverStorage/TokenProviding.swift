import Foundation

/// Поставщик OAuth-токена для облачного адаптера.
///
/// Стор (`YandexDiskStore`) НИКОГДА не хранит креды сам — он получает токен поздно,
/// перед каждым запросом, через эту инъекцию. Это делает смену способа входа
/// тривиальной: MVP даёт `StaticTokenProvider` поверх токена из Keychain
/// (`KeychainKeyStore` приложения, S4-9); позже `ASWebAuthenticationSession`-вход
/// (S4-6) подменит поставщика без правок адаптера.
///
/// `token()` асинхронный и возвращает `nil`, когда токена нет (не залогинен) —
/// адаптер в этом случае немедленно бросает `RemoteError.unauthorized`, не уходя в сеть.
public protocol TokenProviding: Sendable {
    /// Возвращает актуальный OAuth-токен или `nil`, если пользователь не залогинен.
    func token() async -> String?
}

/// Неизменяемый поставщик одного заранее известного токена (или его отсутствия).
///
/// Используется приложением (S4-9): `CloudAccount` читает токен из Keychain и
/// оборачивает в `StaticTokenProvider`; при logout — `StaticTokenProvider(token: nil)`.
/// Потокобезопасен по построению (значение неизменяемо, `Sendable`).
public struct StaticTokenProvider: TokenProviding {
    private let value: String?

    /// - Parameter token: токен или `nil` (не залогинен).
    public init(token: String?) {
        self.value = token
    }

    public func token() async -> String? {
        value
    }
}
