import Foundation

/// ``ChatClient`` для Anthropic Messages API (тип
/// ``BrainAPIKind/anthropicMessages``).
///
/// Один POST `{baseURL}/messages`. Аутентификация у Anthropic — НЕ Bearer:
/// заголовки `x-api-key: <token>` и `anthropic-version: 2023-06-01`. Тело —
/// `{model, max_tokens, system, messages:[{role:"user",content}], temperature}`.
/// `max_tokens` обязателен.
///
/// Инструменты (по конфигу): `webSearch` → нативный тул
/// `tools:[{"type":"web_search_20250305","name":"web_search","max_uses":5}]`.
/// `reasoning ≠ off` → extended thinking `thinking:{"type":"enabled",
/// "budget_tokens": 4k|8k|16k}`, при этом `max_tokens = 8192 + budget` (без
/// thinking `max_tokens = 8192`) и — требование Anthropic — `temperature = 1`
/// (иначе провайдер отклонит запрос с включённым thinking).
///
/// Разбор ответа: `content[]` → конкатенация блоков `type=="text"`; блоки
/// thinking/tool_use пропускаем. Ошибки статусов — общие (``BrainHTTP``).
///
/// `@unchecked Sendable`: `URLSession` потокобезопасна, своего состояния нет.
final class AnthropicMessagesClient: ChatClient, @unchecked Sendable {
    private let config: BrainConfig
    private let tokenProvider: any BrainTokenProviding
    private let session: URLSession

    /// Базовый лимит вывода. При thinking к нему прибавляется бюджет thinking,
    /// чтобы модели хватало и на рассуждение, и на сам ответ.
    private static let baseMaxTokens = 8192

    init(
        config: BrainConfig,
        tokenProvider: any BrainTokenProviding,
        session: URLSession = URLSession(configuration: .default)
    ) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: - ChatClient

    func complete(system: String, user: String) async throws -> String {
        guard let token = await tokenProvider.token(), !token.isEmpty else {
            throw BrainError.missingToken
        }

        let request = try makeRequest(token: token, system: system, user: user)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BrainError.network(BrainHTTP.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw BrainError.badResponse("ответ не является HTTP")
        }
        try BrainHTTP.checkStatus(http, data: data)

        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw BrainError.badResponse("не удалось разобрать ответ: \(BrainHTTP.snippet(from: data))")
        }

        // content[] → берём только текстовые блоки, thinking/tool_use пропускаем.
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()

        guard !text.isEmpty else {
            throw BrainError.badResponse("в ответе нет content[type=text].text")
        }
        return text
    }

    // MARK: - Сборка запроса

    private func makeRequest(token: String, system: String, user: String) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BrainHTTP.timeout(for: config.reasoning)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic-специфика: ключ через x-api-key (не Bearer) + версия API.
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let thinkingBudget = config.reasoning.anthropicThinkingBudget
        let maxTokens = Self.baseMaxTokens + (thinkingBudget ?? 0)
        // При включённом thinking Anthropic требует temperature == 1.
        let temperature = thinkingBudget == nil ? 0.8 : 1.0

        let body = MessagesRequest(
            model: config.model,
            maxTokens: maxTokens,
            system: system,
            messages: [.init(role: "user", content: user)],
            temperature: temperature,
            // Нативный веб-поиск Anthropic — только при включённом тумблере.
            tools: config.webSearch
                ? [.init(type: "web_search_20250305", name: "web_search", maxUses: 5)]
                : nil,
            // extended thinking — только когда рассуждение запрошено.
            thinking: thinkingBudget.map { .init(type: "enabled", budgetTokens: $0) }
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - JSON-модели протокола messages

/// Тело запроса `messages`. Опциональные `tools`/`thinking` при `nil` опускаются.
private struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    /// Нативный веб-поиск Anthropic.
    struct Tool: Encodable {
        let type: String
        let name: String
        let maxUses: Int
        enum CodingKeys: String, CodingKey {
            case type, name
            case maxUses = "max_uses"
        }
    }
    /// Блок extended thinking.
    struct Thinking: Encodable {
        let type: String
        let budgetTokens: Int
        enum CodingKeys: String, CodingKey {
            case type
            case budgetTokens = "budget_tokens"
        }
    }
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let temperature: Double
    let tools: [Tool]?
    let thinking: Thinking?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, temperature, tools, thinking
        case maxTokens = "max_tokens"
    }
}

/// Разбор ответа Anthropic: `content[]` — разнотипные блоки (text/thinking/
/// tool_use). Берём только `text`.
private struct MessagesResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }
    let content: [Block]
}
