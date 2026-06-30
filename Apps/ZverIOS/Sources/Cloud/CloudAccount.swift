import Foundation
import ZverStorage
import ZverTransport

/// Аккаунт облака (Яндекс.Диск): хранит OAuth-токен в Keychain и выдаёт
/// `TokenProviding` для `YandexDiskStore`.
///
/// **MVP-вход — ручной отладочный токен** (см. шапку плана этапа 4): владелец
/// получает ~годовой OAuth-токен (права `cloud_api:disk.read` + `cloud_api:disk.write`,
/// контент в папке `zver-media` в корне Диска) и вставляет его в Настройках. Полноценный `ASWebAuthenticationSession`-вход требует
/// зарегистрированного на oauth.yandex.ru приложения (`client_id`) — отложен
/// (заготовка живёт в `ZverStorage/Auth`, активируется позже без правок этого типа).
///
/// Токен лежит в системном Keychain через переиспользуемый `KeychainKeyStore`
/// из `ZverTransport` — но с ОТДЕЛЬНЫМ аккаунтом `zver-yandex-token`, чтобы не
/// смешиваться с токеном синка Мака (`zver-sync-token`). Сервис-ключ записи —
/// `yandex.disk`.
///
/// `CloudAccount` — `@MainActor ObservableObject`: статус авторизации (`isAuthorized`)
/// драйвит UI. Сам токен в `@Published`-строке НЕ держим открытым дольше нужного —
/// наружу отдаём только маскированный хвост (`maskedToken`) для подтверждения, что
/// «токен сохранён», а боевое значение читается из Keychain поздно, в `tokenProvider`.
@MainActor
final class CloudAccount: ObservableObject {
    /// Аккаунт-метка записи в Keychain — отдельная от токена синка Мака.
    static let keychainAccount = "zver-yandex-token"
    /// Сервис-ключ записи (одна запись на приложение).
    static let service = "yandex.disk"

    /// Залогинен ли пользователь (в Keychain есть непустой токен).
    @Published private(set) var isAuthorized: Bool

    /// Маскированный хвост сохранённого токена для отображения («…a1b2»). `nil`,
    /// если токена нет. Полный токен наружу не выходит.
    @Published private(set) var maskedToken: String?

    private let keyStore: any KeyStore

    /// - Parameter keyStore: хранилище токена. Боевой дефолт — `KeychainKeyStore`
    ///   с аккаунтом `zver-yandex-token`; в превью/тестах можно подменить на
    ///   `InMemoryKeyStore`.
    init(keyStore: any KeyStore = KeychainKeyStore(account: CloudAccount.keychainAccount)) {
        self.keyStore = keyStore
        // На старте читаем токен: есть непустой → авторизованы.
        let existing = keyStore.token(forService: CloudAccount.service)
        if let token = existing, !token.isEmpty {
            self.isAuthorized = true
            self.maskedToken = Self.mask(token)
        } else {
            self.isAuthorized = false
            self.maskedToken = nil
        }
    }

    /// Поставщик токена для `YandexDiskStore`. Читает токен из Keychain ПОЗДНО
    /// (в момент запроса), поэтому стор всегда видит актуальное значение — после
    /// `login`/`logout` пересоздавать поставщика не нужно. `nil` (не залогинен) →
    /// адаптер бросит `RemoteError.unauthorized`, не уходя в сеть.
    var tokenProvider: any TokenProviding {
        KeychainTokenProvider(keyStore: keyStore, service: Self.service)
    }

    /// Сохраняет токен в Keychain и переводит аккаунт в авторизованное состояние.
    ///
    /// Пустой/пробельный токен отвергается (`AccountError.emptyToken`). Токен
    /// тримится от пробелов и переводов строки (типичный мусор при вставке).
    func login(token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountError.emptyToken }
        try keyStore.save(token: trimmed, forService: Self.service)
        isAuthorized = true
        maskedToken = Self.mask(trimmed)
    }

    /// Удаляет токен из Keychain и сбрасывает авторизацию. Идемпотентно.
    func logout() {
        try? keyStore.delete(forService: Self.service)
        isAuthorized = false
        maskedToken = nil
    }

    /// Ошибки входа.
    enum AccountError: Error, LocalizedError {
        case emptyToken

        var errorDescription: String? {
            switch self {
            case .emptyToken: return "Токен пустой — вставьте OAuth-токен Яндекс.Диска."
            }
        }
    }

    /// Маскирует токен до последних 4 символов: «…a1b2». Короткий токен (≤4) —
    /// целиком за многоточием, чтобы не светить значение.
    private static func mask(_ token: String) -> String {
        let tail = token.suffix(4)
        return "…\(tail)"
    }
}

/// `TokenProviding` поверх `KeyStore`: читает токен из Keychain в момент запроса.
///
/// Лежит здесь (а не в `ZverStorage`), потому что `KeyStore` — тип `ZverTransport`,
/// а пакет `ZverStorage` не зависит от него. Адаптер тонкий и `Sendable`: хранит
/// лишь `Sendable`-ссылку на `KeyStore` и строковый ключ сервиса.
struct KeychainTokenProvider: TokenProviding {
    let keyStore: any KeyStore
    let service: String

    func token() async -> String? {
        let value = keyStore.token(forService: service)
        // Пустую строку трактуем как «нет токена».
        if let value, value.isEmpty { return nil }
        return value
    }
}
