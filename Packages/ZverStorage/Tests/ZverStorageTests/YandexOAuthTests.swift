import Testing
import Foundation
@testable import ZverStorage

/// Тесты чистой логики OAuth-входа Яндекса (token-flow, app-folder scope).
///
/// Покрываем ДВЕ чистые функции — построение authorize-URL и разбор redirect:
/// - `authorizeURL(...)` собирает корректный URL `oauth.yandex.ru/authorize` с
///   `response_type=token`, `client_id`, `scope`, `redirect_uri`, `state`;
/// - `parseRedirect(_:)` достаёт `access_token` из fragment редиректа, распознаёт
///   отказ (`error=access_denied`) и мусор (нет токена) как ошибки.
///
/// Рантайм-адаптер (`ASWebAuthSession` на `ASWebAuthenticationSession`) — заготовка
/// под `#if canImport(AuthenticationServices)`, тестами НЕ покрывается (требует
/// зарегистрированного `client_id`, активируется позже).
@Suite struct YandexOAuthTests {
    // MARK: - Хелперы

    /// Разбирает query authorize-URL в словарь имя→значение.
    private func queryItems(_ url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return [:] }
        var dict: [String: String] = [:]
        for item in items {
            dict[item.name] = item.value
        }
        return dict
    }

    // MARK: - authorizeURL

    @Test func authorizeURLPointsAtYandexAuthorizeEndpoint() {
        let url = YandexOAuth.authorizeURL(
            clientID: "abc123",
            scope: "cloud_api:disk.app_folder",
            redirectURI: "zvermedia://oauth",
            state: "xyz"
        )
        #expect(url.scheme == "https")
        #expect(url.host == "oauth.yandex.ru")
        #expect(url.path == "/authorize")
    }

    @Test func authorizeURLCarriesTokenFlowQuery() {
        let url = YandexOAuth.authorizeURL(
            clientID: "abc123",
            scope: "cloud_api:disk.app_folder",
            redirectURI: "zvermedia://oauth",
            state: "xyz"
        )
        let q = queryItems(url)
        #expect(q["response_type"] == "token")
        #expect(q["client_id"] == "abc123")
        #expect(q["scope"] == "cloud_api:disk.app_folder")
        #expect(q["redirect_uri"] == "zvermedia://oauth")
        #expect(q["state"] == "xyz")
    }

    @Test func authorizeURLOmitsStateWhenNil() {
        let url = YandexOAuth.authorizeURL(
            clientID: "abc123",
            scope: "cloud_api:disk.app_folder",
            redirectURI: "zvermedia://oauth",
            state: nil
        )
        let q = queryItems(url)
        #expect(q["state"] == nil)
        #expect(q["response_type"] == "token")
    }

    @Test func authorizeURLPercentEncodesReservedScopeAndRedirect() {
        let url = YandexOAuth.authorizeURL(
            clientID: "id with space",
            scope: "cloud_api:disk.app_folder cloud_api:disk.read",
            redirectURI: "https://example.com/cb?x=1",
            state: nil
        )
        // Значения декодируются обратно корректно (кодирование прозрачно для парсера).
        let q = queryItems(url)
        #expect(q["client_id"] == "id with space")
        #expect(q["scope"] == "cloud_api:disk.app_folder cloud_api:disk.read")
        #expect(q["redirect_uri"] == "https://example.com/cb?x=1")
        // Сырой URL не содержит литеральных пробелов/незакодированного `?` в значениях.
        let raw = url.absoluteString
        #expect(raw.contains(" ") == false)
    }

    // MARK: - parseRedirect: успех

    @Test func parseRedirectExtractsAccessTokenFromFragment() {
        let url = URL(string: "zvermedia://oauth#access_token=TOKEN123&token_type=bearer&expires_in=31536000")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .success("TOKEN123"))
    }

    @Test func parseRedirectExtractsTokenWhenExpiresInPresent() {
        let url = URL(string: "zvermedia://oauth#access_token=abc.def-ghi&expires_in=600")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .success("abc.def-ghi"))
    }

    @Test func parseRedirectExtractsTokenRegardlessOfParamOrder() {
        let url = URL(string: "zvermedia://oauth#expires_in=600&token_type=bearer&access_token=T")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .success("T"))
    }

    @Test func parseRedirectPercentDecodesToken() {
        // На практике токен Яндекса безопасен для URL, но проверяем декодирование значения.
        let url = URL(string: "zvermedia://oauth#access_token=a%2Bb&expires_in=1")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .success("a+b"))
    }

    // MARK: - parseRedirect: отказ и мусор

    @Test func parseRedirectMapsAccessDeniedToDenied() {
        let url = URL(string: "zvermedia://oauth#error=access_denied&error_description=User+denied")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .failure(.denied))
    }

    @Test func parseRedirectMapsErrorInQueryToDenied() {
        // Сервер вправе вернуть error в query (а не fragment) — тоже распознаём.
        let url = URL(string: "zvermedia://oauth?error=access_denied")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .failure(.denied))
    }

    @Test func parseRedirectMapsMissingTokenToMalformed() {
        let url = URL(string: "zvermedia://oauth#token_type=bearer&expires_in=600")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .failure(.malformed))
    }

    @Test func parseRedirectMapsEmptyFragmentToMalformed() {
        let url = URL(string: "zvermedia://oauth")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .failure(.malformed))
    }

    @Test func parseRedirectMapsEmptyTokenValueToMalformed() {
        let url = URL(string: "zvermedia://oauth#access_token=&expires_in=600")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .failure(.malformed))
    }

    @Test func parseRedirectMapsUnknownErrorToDenied() {
        // Любой нестандартный error трактуем как отказ (не наш токен), не как malformed.
        let url = URL(string: "zvermedia://oauth#error=invalid_scope")!
        let result = YandexOAuth.parseRedirect(url)
        #expect(result == .failure(.denied))
    }
}
