import Foundation

/// Боевой ``ChatClient`` поверх `URLSession` для любого OpenAI-совместимого API.
///
/// Один POST `{baseURL}/chat/completions` с телом `{model, messages, temperature}`,
/// Bearer-ключ из ``BrainTokenProviding``. Никаких провайдер-специфичных SDK —
/// OpenRouter / OpenAI / Gemini (в openai-совместимом режиме) отличаются только
/// `baseURL`/`model`/ключом. Сессия инъецируется (в тестах — мок-`URLProtocol`).
///
/// Ретраев нет: запуск ручной. `@unchecked Sendable` оправдан — `URLSession`
/// потокобезопасна, собственного мутабельного состояния у клиента нет.
public final class OpenAICompatibleClient: ChatClient, @unchecked Sendable {
    private let config: BrainConfig
    private let tokenProvider: any BrainTokenProviding
    private let session: URLSession

    /// Таймаут одного запроса. Генерация ленты у медленных моделей — десятки
    /// секунд; берём с запасом, но конечный, чтобы висящий запрос не жил вечно.
    private static let requestTimeout: TimeInterval = 120

    /// Максимум символов тела/причины, попадающих в ``BrainError/badResponse(_:)``
    /// — чтобы ошибка оставалась читаемой, а не тащила килобайты HTML.
    private static let snippetLimit = 500

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
            throw BrainError.network(Self.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw BrainError.badResponse("ответ не является HTTP")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw BrainError.unauthorized
        case 429:
            throw BrainError.rateLimited
        default:
            throw BrainError.badResponse(
                "HTTP \(http.statusCode): \(Self.snippet(from: data))"
            )
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw BrainError.badResponse("не удалось разобрать ответ: \(Self.snippet(from: data))")
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
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = ChatCompletionRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            temperature: 0.8
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Диагностика

    /// Короткий человекочитаемый фрагмент тела ответа для ошибки.
    private static func snippet(from data: Data) -> String {
        guard !data.isEmpty else { return "(пустое тело)" }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= snippetLimit { return text }
        return String(text.prefix(snippetLimit)) + "…"
    }

    /// Описание транспортной ошибки без утечки внутренних типов в API.
    private static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue))"
        }
        return String(describing: error)
    }
}

// MARK: - JSON-модели протокола chat/completions

/// Тело запроса `chat/completions` (минимальное подмножество: то, что нужно).
private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let model: String
    let messages: [Message]
    let temperature: Double
}

/// Разбор ответа: интересует только `choices[0].message.content`.
private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}
