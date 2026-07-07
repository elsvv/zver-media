import Foundation

/// Точка сборки ``ChatClient`` по ``BrainConfig``.
///
/// Один вход для приложения: по `config.kind` выбирает нужный адаптер
/// (chat/completions, responses или messages). Конкретные типы адаптеров —
/// деталь реализации за этим фасадом; наружу — только `any ChatClient`.
public enum BrainClientFactory {
    /// Собирает адаптер под тип API из конфига.
    /// - Parameters:
    ///   - config: конфигурация (несёт `kind`/`webSearch`/`reasoning`).
    ///   - tokenProvider: поставщик ключа (Bearer или x-api-key — решает адаптер).
    ///   - session: сессия (в тестах — с мок-`URLProtocol`).
    public static func make(
        config: BrainConfig,
        tokenProvider: any BrainTokenProviding,
        session: URLSession = URLSession(configuration: .default)
    ) -> any ChatClient {
        switch config.kind {
        case .chatCompletions:
            return OpenAICompatibleClient(config: config, tokenProvider: tokenProvider, session: session)
        case .openaiResponses:
            return OpenAIResponsesClient(config: config, tokenProvider: tokenProvider, session: session)
        case .anthropicMessages:
            return AnthropicMessagesClient(config: config, tokenProvider: tokenProvider, session: session)
        }
    }
}
