import Testing
import Foundation
@testable import ZverBrain

// MARK: - Общие помощники сетевых тестов

/// Мок-сессия с перехватом через ``MockURLProtocol``.
private func mockSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: cfg)
}

/// Тело последнего запроса, разобранное в JSON-объект (проверяем СТРУКТУРУ,
/// а не подстроки — так тест не ломается от порядка ключей и экранирования).
private func lastBody() throws -> [String: Any] {
    let data = try #require(MockURLProtocol.lastRequestBody(), "нет тела запроса")
    let obj = try JSONSerialization.jsonObject(with: data)
    return try #require(obj as? [String: Any], "тело не JSON-объект")
}

private func lastURLPath() -> String { MockURLProtocol.lastRequestURL()?.path ?? "" }
private func lastHeaders() -> [String: String] { MockURLProtocol.lastRequestHeaders() ?? [:] }

/// Имя кейса ``BrainError`` без ассоциированных значений (для сравнения ветвей).
private func caseName(_ error: BrainError) -> String {
    switch error {
    case .unauthorized: return "unauthorized"
    case .rateLimited: return "rateLimited"
    case .badResponse: return "badResponse"
    case .network: return "network"
    case .missingToken: return "missingToken"
    }
}

/// Ждёт от операции конкретный кейс ``BrainError`` (по имени, без payload).
private func expectError(_ expected: String, _ op: () async throws -> String) async {
    do {
        _ = try await op()
        Issue.record("ожидалась ошибка .\(expected)")
    } catch let error as BrainError {
        #expect(caseName(error) == expected)
    } catch {
        Issue.record("неожиданный тип ошибки: \(error)")
    }
}

/// Все сетевые тесты трёх адаптеров — под ОДНИМ `.serialized`-зонтиком.
///
/// ``MockURLProtocol`` держит общий стаб в статике. Несколько независимых
/// `.serialized`-сьютов параллелятся МЕЖДУ собой и гоняются за этим стабом;
/// вложение в один serialized-родитель применяет сериализацию рекурсивно ко
/// всем вложенным сьютам и убирает гонку.
@Suite(.serialized)
struct BrainNetworkTests {

    // MARK: - chat/completions (OpenAICompatibleClient)

    @Suite struct ChatCompletions {
        private static let okBody = #"{"choices":[{"message":{"content":"Готово"}}]}"#

        private func makeClient(
            token: String? = "sk-test",
            webSearch: Bool = false,
            reasoning: BrainReasoning = .off
        ) -> OpenAICompatibleClient {
            OpenAICompatibleClient(
                config: BrainConfig(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "test-model",
                    kind: .chatCompletions,
                    webSearch: webSearch,
                    reasoning: reasoning
                ),
                tokenProvider: StaticBrainTokenProvider(token: token),
                session: mockSession()
            )
        }

        // Успех и разбор

        @Test func successReturnsContent() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            let text = try await makeClient().complete(system: "SYS", user: "USR")
            #expect(text == "Готово")
        }

        // Endpoint и заголовки

        @Test func hitsChatCompletionsPath() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient().complete(system: "s", user: "u")
            #expect(lastURLPath().hasSuffix("/chat/completions"))
        }

        @Test func sendsBearerAuthorization() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(token: "sk-XYZ").complete(system: "s", user: "u")
            #expect(lastHeaders()["Authorization"] == "Bearer sk-XYZ")
            #expect(lastHeaders()["x-api-key"] == nil)
        }

        // Тело: модель, сообщения, температура

        @Test func bodyCarriesModelMessagesAndTemperature() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient().complete(system: "SYSTEM-MARK", user: "USER-MARK")

            let body = try lastBody()
            #expect(body["model"] as? String == "test-model")
            #expect(body["temperature"] as? Double == 0.8)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages[0]["role"] as? String == "system")
            #expect(messages[0]["content"] as? String == "SYSTEM-MARK")
            #expect(messages[1]["role"] as? String == "user")
            #expect(messages[1]["content"] as? String == "USER-MARK")
        }

        // Инструменты: веб-поиск (плагин OpenRouter)

        @Test func noPluginsWhenWebSearchOff() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(webSearch: false).complete(system: "s", user: "u")
            #expect(try lastBody()["plugins"] == nil)
        }

        @Test func webSearchAddsOpenRouterWebPlugin() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(webSearch: true).complete(system: "s", user: "u")
            let plugins = try #require(try lastBody()["plugins"] as? [[String: Any]])
            #expect(plugins.count == 1)
            #expect(plugins.first?["id"] as? String == "web")
        }

        // Рассуждение: reasoning_effort

        @Test func noReasoningEffortWhenOff() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(reasoning: .off).complete(system: "s", user: "u")
            #expect(try lastBody()["reasoning_effort"] == nil)
        }

        @Test func reasoningMapsToEffortString() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(reasoning: .medium).complete(system: "s", user: "u")
            #expect(try lastBody()["reasoning_effort"] as? String == "medium")
        }

        // Ошибки статусов

        @Test func status401IsUnauthorized() async {
            MockURLProtocol.setStub(.init(statusCode: 401))
            await expectError("unauthorized") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func status403IsUnauthorized() async {
            MockURLProtocol.setStub(.init(statusCode: 403))
            await expectError("unauthorized") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func status429IsRateLimited() async {
            MockURLProtocol.setStub(.init(statusCode: 429))
            await expectError("rateLimited") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func status500IsBadResponse() async {
            MockURLProtocol.setStub(.init(statusCode: 500, body: Data("boom".utf8)))
            await expectError("badResponse") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func status500BadResponseCarriesBodySnippet() async throws {
            MockURLProtocol.setStub(.init(statusCode: 500, body: Data("SERVER-EXPLODED".utf8)))
            do {
                _ = try await makeClient().complete(system: "s", user: "u")
                Issue.record("ожидалась ошибка")
            } catch let BrainError.badResponse(message) {
                #expect(message.contains("500"))
                #expect(message.contains("SERVER-EXPLODED"))
            }
        }

        // Битый ответ и токен

        @Test func malformedJSONIsBadResponse() async {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data("не json вовсе".utf8)))
            await expectError("badResponse") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func emptyChoicesIsBadResponse() async {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(#"{"choices":[]}"#.utf8)))
            await expectError("badResponse") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func missingTokenShortCircuitsBeforeNetwork() async {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            await expectError("missingToken") { try await makeClient(token: nil).complete(system: "s", user: "u") }
        }

        @Test func emptyTokenIsMissingToken() async {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            await expectError("missingToken") { try await makeClient(token: "").complete(system: "s", user: "u") }
        }

        @Test func transportFailureIsNetwork() async {
            MockURLProtocol.setStub(.init(statusCode: 0, error: URLError(.notConnectedToInternet)))
            await expectError("network") { try await makeClient().complete(system: "s", user: "u") }
        }
    }

    // MARK: - responses (OpenAIResponsesClient)

    @Suite struct Responses {
        /// Ответ Responses: reasoning-элемент (пропускаем) + message с двумя
        /// output_text-частями (конкатенация) — проверяем оба фильтра.
        private static let okBody = """
        {"output":[
          {"type":"reasoning","summary":[]},
          {"type":"message","role":"assistant","content":[
            {"type":"output_text","text":"Го","annotations":[]},
            {"type":"output_text","text":"тово","annotations":[]}
          ]}
        ]}
        """

        private func makeClient(
            token: String? = "sk-test",
            webSearch: Bool = false,
            reasoning: BrainReasoning = .off
        ) -> OpenAIResponsesClient {
            OpenAIResponsesClient(
                config: BrainConfig(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "gpt-x",
                    kind: .openaiResponses,
                    webSearch: webSearch,
                    reasoning: reasoning
                ),
                tokenProvider: StaticBrainTokenProvider(token: token),
                session: mockSession()
            )
        }

        // Разбор ответа

        @Test func concatenatesOutputTextSkippingNonMessage() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            let text = try await makeClient().complete(system: "s", user: "u")
            #expect(text == "Готово")
        }

        @Test func emptyOutputTextIsBadResponse() async {
            // message есть, но текстовых частей нет — только refusal.
            let body = #"{"output":[{"type":"message","content":[{"type":"refusal","refusal":"нет"}]}]}"#
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(body.utf8)))
            await expectError("badResponse") { try await makeClient().complete(system: "s", user: "u") }
        }

        // Endpoint и заголовки

        @Test func hitsResponsesPath() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient().complete(system: "s", user: "u")
            #expect(lastURLPath().hasSuffix("/responses"))
        }

        @Test func sendsBearerAuthorization() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(token: "sk-RSP").complete(system: "s", user: "u")
            #expect(lastHeaders()["Authorization"] == "Bearer sk-RSP")
        }

        // Тело: instructions=system, input=user, temperature

        @Test func bodyMapsSystemToInstructionsAndUserToInput() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient().complete(system: "SYS-MARK", user: "USR-MARK")
            let body = try lastBody()
            #expect(body["model"] as? String == "gpt-x")
            #expect(body["instructions"] as? String == "SYS-MARK")
            #expect(body["input"] as? String == "USR-MARK")
            #expect(body["temperature"] as? Double == 0.8)
        }

        // Инструменты: нативный web_search

        @Test func noToolsWhenWebSearchOff() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(webSearch: false).complete(system: "s", user: "u")
            #expect(try lastBody()["tools"] == nil)
        }

        @Test func webSearchAddsNativeWebSearchTool() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(webSearch: true).complete(system: "s", user: "u")
            let tools = try #require(try lastBody()["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            #expect(tools.first?["type"] as? String == "web_search")
        }

        // Рассуждение: reasoning.effort

        @Test func noReasoningWhenOff() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(reasoning: .off).complete(system: "s", user: "u")
            #expect(try lastBody()["reasoning"] == nil)
        }

        @Test func reasoningMapsToEffortObject() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(reasoning: .high).complete(system: "s", user: "u")
            let reasoning = try #require(try lastBody()["reasoning"] as? [String: Any])
            #expect(reasoning["effort"] as? String == "high")
        }

        // Ошибки статусов

        @Test func status401IsUnauthorized() async {
            MockURLProtocol.setStub(.init(statusCode: 401))
            await expectError("unauthorized") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func status429IsRateLimited() async {
            MockURLProtocol.setStub(.init(statusCode: 429))
            await expectError("rateLimited") { try await makeClient().complete(system: "s", user: "u") }
        }
    }

    // MARK: - messages (AnthropicMessagesClient)

    @Suite struct AnthropicMessages {
        /// Ответ Anthropic: thinking-блок (пропускаем) + text-блок.
        private static let okBody = """
        {"content":[
          {"type":"thinking","thinking":"рассуждаю про себя"},
          {"type":"text","text":"Готово"}
        ]}
        """

        private func makeClient(
            token: String? = "sk-ant",
            webSearch: Bool = false,
            reasoning: BrainReasoning = .off
        ) -> AnthropicMessagesClient {
            AnthropicMessagesClient(
                config: BrainConfig(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "claude-x",
                    kind: .anthropicMessages,
                    webSearch: webSearch,
                    reasoning: reasoning
                ),
                tokenProvider: StaticBrainTokenProvider(token: token),
                session: mockSession()
            )
        }

        // Разбор ответа: только text-блоки

        @Test func concatenatesTextSkippingThinkingBlocks() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            let text = try await makeClient().complete(system: "s", user: "u")
            #expect(text == "Готово")
        }

        @Test func onlyThinkingBlocksIsBadResponse() async {
            let body = #"{"content":[{"type":"thinking","thinking":"только мысли"}]}"#
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(body.utf8)))
            await expectError("badResponse") { try await makeClient().complete(system: "s", user: "u") }
        }

        // Endpoint и заголовки: x-api-key + anthropic-version, НЕ Bearer

        @Test func hitsMessagesPath() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient().complete(system: "s", user: "u")
            #expect(lastURLPath().hasSuffix("/messages"))
        }

        @Test func sendsApiKeyAndVersionNotBearer() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(token: "sk-ANT-123").complete(system: "s", user: "u")
            let headers = lastHeaders()
            #expect(headers["x-api-key"] == "sk-ANT-123")
            #expect(headers["anthropic-version"] == "2023-06-01")
            #expect(headers["Authorization"] == nil)
        }

        // Тело: system, messages, max_tokens

        @Test func bodyCarriesSystemUserMessageAndMaxTokens() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient().complete(system: "SYS-MARK", user: "USR-MARK")
            let body = try lastBody()
            #expect(body["model"] as? String == "claude-x")
            #expect(body["system"] as? String == "SYS-MARK")
            #expect(body["max_tokens"] as? Int == 8192)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            #expect(messages[0]["role"] as? String == "user")
            #expect(messages[0]["content"] as? String == "USR-MARK")
        }

        // max_tokens и temperature без thinking

        @Test func withoutThinkingMaxTokens8192AndTemperature08() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(reasoning: .off).complete(system: "s", user: "u")
            let body = try lastBody()
            #expect(body["max_tokens"] as? Int == 8192)
            #expect(body["temperature"] as? Double == 0.8)
            #expect(body["thinking"] == nil)
        }

        // max_tokens, thinking и temperature=1 с thinking

        @Test func withThinkingAddsBudgetMaxTokensAndTemperature1() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(reasoning: .medium).complete(system: "s", user: "u")
            let body = try lastBody()
            // medium → budget 8192, max_tokens = 8192 + 8192.
            #expect(body["max_tokens"] as? Int == 16384)
            #expect(body["temperature"] as? Double == 1.0)
            let thinking = try #require(body["thinking"] as? [String: Any])
            #expect(thinking["type"] as? String == "enabled")
            #expect(thinking["budget_tokens"] as? Int == 8192)
        }

        @Test func highThinkingBudgetIs16k() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(reasoning: .high).complete(system: "s", user: "u")
            let body = try lastBody()
            #expect(body["max_tokens"] as? Int == 8192 + 16384)
            let thinking = try #require(body["thinking"] as? [String: Any])
            #expect(thinking["budget_tokens"] as? Int == 16384)
        }

        // Инструменты: нативный web_search Anthropic

        @Test func noToolsWhenWebSearchOff() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(webSearch: false).complete(system: "s", user: "u")
            #expect(try lastBody()["tools"] == nil)
        }

        @Test func webSearchAddsAnthropicWebSearchTool() async throws {
            MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
            _ = try await makeClient(webSearch: true).complete(system: "s", user: "u")
            let tools = try #require(try lastBody()["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            let tool = try #require(tools.first)
            #expect(tool["type"] as? String == "web_search_20250305")
            #expect(tool["name"] as? String == "web_search")
            #expect(tool["max_uses"] as? Int == 5)
        }

        // Ошибки статусов

        @Test func status401IsUnauthorized() async {
            MockURLProtocol.setStub(.init(statusCode: 401))
            await expectError("unauthorized") { try await makeClient().complete(system: "s", user: "u") }
        }

        @Test func status429IsRateLimited() async {
            MockURLProtocol.setStub(.init(statusCode: 429))
            await expectError("rateLimited") { try await makeClient().complete(system: "s", user: "u") }
        }
    }

    // MARK: - Фабрика

    @Suite struct Factory {
        private func client(for kind: BrainAPIKind) -> any ChatClient {
            BrainClientFactory.make(
                config: BrainConfig(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "m",
                    kind: kind
                ),
                tokenProvider: StaticBrainTokenProvider(token: "sk"),
                session: mockSession()
            )
        }

        @Test func chatCompletionsBuildsCompatibleClient() {
            #expect(client(for: .chatCompletions) is OpenAICompatibleClient)
        }

        @Test func openaiResponsesBuildsResponsesClient() {
            #expect(client(for: .openaiResponses) is OpenAIResponsesClient)
        }

        @Test func anthropicMessagesBuildsAnthropicClient() {
            #expect(client(for: .anthropicMessages) is AnthropicMessagesClient)
        }
    }
}
