import Foundation

/// ``ChatClient`` для нового OpenAI Responses API (тип
/// ``BrainAPIKind/openaiResponses``).
///
/// Один POST `{baseURL}/responses` с телом `{model, instructions, input,
/// temperature}`, Bearer-ключ. `instructions` = system-промпт, `input` = user.
/// Инструменты (по конфигу): `webSearch` → `tools:[{"type":"web_search"}]`
/// (нативный тул), `reasoning ≠ off` → `reasoning:{"effort": low|medium|high}`.
///
/// Разбор ответа: массив `output[]` → элементы `type=="message"` → их `content[]`
/// с `type=="output_text"` → конкатенация `text`. Пустой текст → badResponse.
/// Ошибки статусов — как в остальных адаптерах (``BrainHTTP``).
///
/// `@unchecked Sendable`: `URLSession` потокобезопасна, своего состояния нет.
final class OpenAIResponsesClient: ChatClient, @unchecked Sendable {
    private let config: BrainConfig
    private let tokenProvider: any BrainTokenProviding
    private let session: URLSession

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

        let decoded: ResponsesResponse
        do {
            decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        } catch {
            throw BrainError.badResponse("не удалось разобрать ответ: \(BrainHTTP.snippet(from: data))")
        }

        // output[] → элементы message → content[] output_text → текст.
        let text = decoded.output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap { $0.text }
            .joined()

        guard !text.isEmpty else {
            throw BrainError.badResponse("в ответе нет output[].content[type=output_text].text")
        }
        return text
    }

    // MARK: - Сборка запроса

    private func makeRequest(token: String, system: String, user: String) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("responses")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = BrainHTTP.timeout(for: config.reasoning)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = ResponsesRequest(
            model: config.model,
            instructions: system,
            input: user,
            temperature: 0.8,
            // Нативный веб-поиск — только при включённом тумблере.
            tools: config.webSearch ? [.init(type: "web_search")] : nil,
            // reasoning:{effort} — только когда рассуждение запрошено.
            reasoning: config.reasoning.effort.map { .init(effort: $0) }
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

// MARK: - JSON-модели протокола responses

/// Тело запроса `responses`. Опциональные `tools`/`reasoning` при `nil`
/// опускаются (`encodeIfPresent`).
private struct ResponsesRequest: Encodable {
    struct Tool: Encodable { let type: String }
    struct Reasoning: Encodable { let effort: String }
    let model: String
    let instructions: String
    let input: String
    let temperature: Double
    let tools: [Tool]?
    let reasoning: Reasoning?
}

/// Разбор ответа Responses: `output[]` (сообщения) → `content[]` (части).
/// Поля не из нашего интереса (id/status/annotations и пр.) игнорируются.
private struct ResponsesResponse: Decodable {
    struct OutputItem: Decodable {
        let type: String
        let content: [ContentPart]?
    }
    struct ContentPart: Decodable {
        let type: String
        let text: String?
    }
    let output: [OutputItem]
}
