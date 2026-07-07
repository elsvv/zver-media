import Foundation

/// ``ChatClient`` поверх `URLSession` для любого OpenAI-совместимого API
/// (тип ``BrainAPIKind/chatCompletions``).
///
/// Один POST `{baseURL}/chat/completions` с телом `{model, messages, temperature}`,
/// Bearer-ключ из ``BrainTokenProviding``. Никаких провайдер-специфичных SDK —
/// OpenRouter / OpenAI / Gemini (в openai-совместимом режиме) отличаются только
/// `baseURL`/`model`/ключом. Сессия инъецируется (в тестах — мок-`URLProtocol`).
///
/// Инструменты (по конфигу): `webSearch` → `plugins:[{id:"web"}]` — это плагин
/// OpenRouter; другие провайдеры поле проигнорируют или ответят ошибкой — это
/// осознанно (в UI опция помечена «через OpenRouter»). `reasoning ≠ off` →
/// `reasoning_effort: low|medium|high` (стандарт OpenAI, OpenRouter нормализует).
///
/// Ретраев нет: запуск ручной. `@unchecked Sendable` оправдан — `URLSession`
/// потокобезопасна, собственного мутабельного состояния у клиента нет.
public final class OpenAICompatibleClient: ChatClient, @unchecked Sendable {
    private let config: BrainConfig
    private let tokenProvider: any BrainTokenProviding
    private let session: URLSession

    public init(
        config: BrainConfig,
        tokenProvider: any BrainTokenProviding,
        session: URLSession = URLSession(configuration: .default)
    ) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: - ChatClient

    public func complete(system: String, user: String) async throws -> String {
        // Ключ получаем поздно, перед запросом. Пусто/nil → в сеть не идём.
        guard let token = await tokenProvider.token(), !token.isEmpty else {
            throw BrainError.missingToken
        }

        let request = try makeRequest(token: token, system: system, user: user)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Транспортный сбой (нет сети, таймаут, обрыв) — до HTTP-статуса.
            throw BrainError.network(BrainHTTP.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw BrainError.badResponse("ответ не является HTTP")
        }
        try BrainHTTP.checkStatus(http, data: data)

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw BrainError.badResponse("не удалось разобрать ответ: \(BrainHTTP.snippet(from: data))")
        }

        guard let content = decoded.choices.first?.message.content else {
            throw BrainError.badResponse("в ответе нет choices[0].message.content")
        }
        return content
    }

    // MARK: - Сборка запроса

    private func makeRequest(token: String, system: String, user: String) throws -> URLRequest {
        // appendingPathComponent корректно склеивает и с хвостовым «/», и без него.
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BrainHTTP.timeout(for: config.reasoning)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = ChatCompletionRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            temperature: 0.8,
            // Плагин веб-поиска OpenRouter — только при включённом тумблере.
            plugins: config.webSearch ? [.init(id: "web")] : nil,
            // reasoning_effort — только когда рассуждение запрошено (off → nil → поле опущено).
            reasoningEffort: config.reasoning.effort
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - JSON-модели протокола chat/completions

/// Тело запроса `chat/completions` (минимальное подмножество: то, что нужно).
///
/// Опциональные `plugins`/`reasoningEffort` кодируются через `encodeIfPresent`
/// (синтез Encodable для Optional) — при `nil` ключ в JSON не попадает.
private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    /// Плагин OpenRouter (`{"id":"web"}` для веб-поиска).
    struct Plugin: Encodable {
        let id: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
    let plugins: [Plugin]?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, plugins
        case reasoningEffort = "reasoning_effort"
    }
}

/// Разбор ответа: интересует только `choices[0].message.content`.
private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
