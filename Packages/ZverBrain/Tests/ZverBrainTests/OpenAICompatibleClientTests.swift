import Testing
import Foundation
@testable import ZverBrain

/// Тесты ``OpenAICompatibleClient`` через мок-`URLProtocol`.
///
/// Suite `.serialized`: мок-протокол держит общий стаб в статике, а swift-testing
/// по умолчанию гоняет тесты параллельно — сериализация исключает гонку за стабом.
@Suite(.serialized)
struct OpenAICompatibleClientTests {
    /// Валидный ответ chat/completions с текстом «Готово».
    private static let okBody = #"{"choices":[{"message":{"content":"Готово"}}]}"#

    private func makeClient(token: String? = "sk-test") -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return OpenAICompatibleClient(
            config: BrainConfig(baseURL: URL(string: "https://api.example.com/v1")!, model: "test-model"),
            tokenProvider: StaticBrainTokenProvider(token: token),
            session: session
        )
    }

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

    // MARK: - Успех

    @Test func successReturnsContent() async throws {
        MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
        let client = makeClient()
        let text = try await client.complete(system: "SYS", user: "USR")
        #expect(text == "Готово")
    }

    @Test func requestCarriesModelMessagesAndTemperature() async throws {
        MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
        let client = makeClient()
        _ = try await client.complete(system: "SYSTEM-MARK", user: "USER-MARK")

        let sent = try #require(MockURLProtocol.lastRequestBody())
        let json = String(decoding: sent, as: UTF8.self)
        #expect(json.contains("test-model"))
        #expect(json.contains("SYSTEM-MARK"))
        #expect(json.contains("USER-MARK"))
        #expect(json.contains("\"system\""))
        #expect(json.contains("\"user\""))
        #expect(json.contains("0.8")) // temperature
    }

    // MARK: - Ошибки статусов

    @Test func status401IsUnauthorized() async {
        MockURLProtocol.setStub(.init(statusCode: 401))
        let client = makeClient()
        await expectError("unauthorized") { try await client.complete(system: "s", user: "u") }
    }

    @Test func status403IsUnauthorized() async {
        MockURLProtocol.setStub(.init(statusCode: 403))
        let client = makeClient()
        await expectError("unauthorized") { try await client.complete(system: "s", user: "u") }
    }

    @Test func status429IsRateLimited() async {
        MockURLProtocol.setStub(.init(statusCode: 429))
        let client = makeClient()
        await expectError("rateLimited") { try await client.complete(system: "s", user: "u") }
    }

    @Test func status500IsBadResponse() async {
        MockURLProtocol.setStub(.init(statusCode: 500, body: Data("boom".utf8)))
        let client = makeClient()
        await expectError("badResponse") { try await client.complete(system: "s", user: "u") }
    }

    @Test func status500BadResponseCarriesBodySnippet() async throws {
        MockURLProtocol.setStub(.init(statusCode: 500, body: Data("SERVER-EXPLODED".utf8)))
        let client = makeClient()
        do {
            _ = try await client.complete(system: "s", user: "u")
            Issue.record("ожидалась ошибка")
        } catch let BrainError.badResponse(message) {
            #expect(message.contains("500"))
            #expect(message.contains("SERVER-EXPLODED"))
        }
    }

    // MARK: - Битый ответ и токен

    @Test func malformedJSONIsBadResponse() async {
        MockURLProtocol.setStub(.init(statusCode: 200, body: Data("не json вовсе".utf8)))
        let client = makeClient()
        await expectError("badResponse") { try await client.complete(system: "s", user: "u") }
    }

    @Test func emptyChoicesIsBadResponse() async {
        MockURLProtocol.setStub(.init(statusCode: 200, body: Data(#"{"choices":[]}"#.utf8)))
        let client = makeClient()
        await expectError("badResponse") { try await client.complete(system: "s", user: "u") }
    }

    @Test func missingTokenShortCircuitsBeforeNetwork() async {
        // Стаб не важен: до сети не доходим.
        MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
        let client = makeClient(token: nil)
        await expectError("missingToken") { try await client.complete(system: "s", user: "u") }
    }

    @Test func emptyTokenIsMissingToken() async {
        MockURLProtocol.setStub(.init(statusCode: 200, body: Data(Self.okBody.utf8)))
        let client = makeClient(token: "")
        await expectError("missingToken") { try await client.complete(system: "s", user: "u") }
    }

    // MARK: - Транспорт

    @Test func transportFailureIsNetwork() async {
        MockURLProtocol.setStub(.init(statusCode: 0, error: URLError(.notConnectedToInternet)))
        let client = makeClient()
        await expectError("network") { try await client.complete(system: "s", user: "u") }
    }
}
