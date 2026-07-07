import Foundation
import ZverBrain
import ZverTransport

/// Аккаунт «Интеллекта» (LLM для рекомендаций): API-ключ в Keychain,
/// base URL и модель — в `UserDefaults` (не секреты). Зеркало `CloudAccount`.
///
/// Провайдер — любой OpenAI-совместимый endpoint: OpenRouter (дефолт),
/// OpenAI, Gemini (openai-совместимый URL) и т.п. — меняется только
/// base URL + модель + ключ, код один.
///
/// Ключ лежит через переиспользуемый `KeychainKeyStore` (`ZverTransport`) с
/// ОТДЕЛЬНЫМ аккаунтом `zver-brain-key` (не смешивается с токенами синка и
/// Яндекса). Наружу — только маскированный хвост.
@MainActor
final class BrainAccount: ObservableObject {
    static let keychainAccount = "zver-brain-key"
    static let service = "brain.llm"
    static let baseURLKey = "brain.baseURL"
    static let modelKey = "brain.model"
    static let defaultBaseURL = "https://openrouter.ai/api/v1"

    /// Ключ сохранён — можно генерировать ленту.
    @Published private(set) var isConfigured: Bool
    /// Маскированный хвост ключа («…a1b2»), nil — ключа нет.
    @Published private(set) var maskedKey: String?

    private let keyStore: any KeyStore

    init(keyStore: any KeyStore = KeychainKeyStore(account: BrainAccount.keychainAccount)) {
        self.keyStore = keyStore
        let existing = keyStore.token(forService: Self.service)
        if let key = existing, !key.isEmpty {
            isConfigured = true
            maskedKey = Self.mask(key)
        } else {
            isConfigured = false
            maskedKey = nil
        }
    }

    /// Конфиг клиента из настроек. Кривой/пустой base URL → nil (UI покажет
    /// подсказку). Модель обязательна — у OpenAI-совместимых API нет дефолта.
    var config: BrainConfig? {
        let defaults = UserDefaults.standard
        let rawURL = defaults.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        let model = defaults.string(forKey: Self.modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true,
              !model.isEmpty
        else { return nil }
        return BrainConfig(baseURL: url, model: model)
    }

    /// Поставщик ключа для `OpenAICompatibleClient`: читает Keychain поздно,
    /// в момент запроса (после save/clear пересоздавать не нужно).
    var tokenProvider: any BrainTokenProviding {
        LateKeychainProvider(keyStore: keyStore, service: Self.service)
    }

    func save(key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountError.emptyToken }
        try keyStore.save(token: trimmed, forService: Self.service)
        isConfigured = true
        maskedKey = Self.mask(trimmed)
    }

    func clear() {
        try? keyStore.delete(forService: Self.service)
        isConfigured = false
        maskedKey = nil
    }

    enum AccountError: Error { case emptyToken }

    private static func mask(_ token: String) -> String {
        "…\(token.suffix(4))"
    }

    private struct LateKeychainProvider: BrainTokenProviding {
        let keyStore: any KeyStore
        let service: String
        func token() async -> String? {
            let value = keyStore.token(forService: service)
            return (value?.isEmpty == false) ? value : nil
        }
    }
}
