import Foundation

/// Ошибка разбора OAuth-redirect Яндекса.
///
/// `parseRedirect(_:)` возвращает её в `.failure`, когда токен не получен:
/// пользователь отказал во входе (`denied`) либо redirect не несёт ни токена,
/// ни распознаваемой ошибки (`malformed`).
public enum OAuthError: Error, Sendable, Equatable {
    /// Сервер вернул `error=...` (отказ во входе или иной OAuth-error) —
    /// токена не будет, нужен повтор входа.
    case denied
    /// Redirect не содержит `access_token` и не несёт `error` — нераспознанный
    /// ответ (битый callback, отсутствует fragment, пустой токен).
    case malformed
}

/// Чистая логика OAuth-входа на Яндекс (implicit/token-flow, app-folder scope).
///
/// Две функции без сети и UI:
/// - ``authorizeURL(clientID:scope:redirectURI:state:)`` строит URL экрана согласия
///   `https://oauth.yandex.ru/authorize` с `response_type=token` — после согласия
///   Яндекс редиректит на `redirect_uri` с токеном в URL-fragment;
/// - ``parseRedirect(_:)`` достаёт `access_token` из fragment этого redirect.
///
/// Обе покрыты TDD на литералах. Рантайм-обвязка (открыть URL, поймать redirect) —
/// заготовка адаптера ``WebAuthSession`` на `ASWebAuthenticationSession`, активируется
/// позже (требует зарегистрированного на oauth.yandex.ru `client_id`). MVP-вход в
/// приложении — ручной токен в Keychain (S4-9), эта чистая логика готова заранее,
/// чтобы подключить браузерный вход тонким адаптером без переделок.
public enum YandexOAuth {
    /// База OAuth-эндпоинта Яндекса.
    static let authorizeEndpoint = URL(string: "https://oauth.yandex.ru/authorize")!

    // MARK: - authorize URL

    /// Строит URL экрана согласия Яндекса для token-flow (`response_type=token`).
    ///
    /// При успешном входе Яндекс редиректит на `redirectURI` с
    /// `#access_token=<...>&token_type=bearer&expires_in=<...>` в fragment, который
    /// затем читает ``parseRedirect(_:)``.
    ///
    /// - Parameters:
    ///   - clientID: идентификатор приложения, зарегистрированного на oauth.yandex.ru.
    ///   - scope: запрашиваемые права, для бэкапа — `cloud_api:disk.app_folder`.
    ///   - redirectURI: callback-URI приложения (его схему ловит `ASWebAuthenticationSession`).
    ///   - state: необязательный CSRF-токен; эхо-возвращается в redirect для сверки.
    ///     `nil` — параметр `state` не добавляется.
    /// - Returns: готовый URL для открытия в браузерной сессии входа.
    public static func authorizeURL(
        clientID: String,
        scope: String,
        redirectURI: String,
        state: String?
    ) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "token"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        if let state {
            items.append(URLQueryItem(name: "state", value: state))
        }
        comps.queryItems = items
        // URLComponents кодирует пробелы в query как "+" (форма application/x-www-form-
        // urlencoded), но oauth.yandex.ru ожидает RFC 3986 (%20). Приводим "+" к %2B,
        // чтобы пробелы в scope/redirect не сливались с плюсом и декодировались обратно
        // однозначно (зеркало YandexRequestFactory).
        if let raw = comps.percentEncodedQuery {
            comps.percentEncodedQuery = raw.replacingOccurrences(of: "+", with: "%2B")
        }
        return comps.url!
    }

    // MARK: - parse redirect

    /// Разбирает redirect от Яндекса: достаёт `access_token` из fragment.
    ///
    /// Token-flow кладёт токен в URL-fragment (`#access_token=...`). Если вместо токена
    /// сервер прислал `error=...` (в fragment ИЛИ в query) — это отказ (`.denied`).
    /// Нет ни токена, ни ошибки (или токен пустой) — `.malformed`.
    ///
    /// - Parameter url: пойманный callback-URL (схема = `redirect_uri` приложения).
    /// - Returns: `.success(token)` или `.failure(OAuthError)`.
    public static func parseRedirect(_ url: URL) -> Result<String, OAuthError> {
        let fragmentParams = parameters(from: url.fragment)
        let queryParams: [String: String] = {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let items = comps.queryItems else { return [:] }
            var dict: [String: String] = [:]
            for item in items {
                dict[item.name] = item.value ?? ""
            }
            return dict
        }()

        // Токен — приоритетно из fragment (token-flow), затем (на всякий) из query.
        if let token = fragmentParams["access_token"] ?? queryParams["access_token"],
           token.isEmpty == false {
            return .success(token)
        }
        // Ошибка входа — fragment или query.
        if fragmentParams["error"] != nil || queryParams["error"] != nil {
            return .failure(.denied)
        }
        return .failure(.malformed)
    }

    // MARK: - Внутреннее

    /// Парсит `key=value&key2=value2`-строку (fragment) в словарь с percent-декодированием.
    ///
    /// Используем ручной разбор (а не `URLComponents`), т.к. fragment не разбивается
    /// им на query-компоненты. Пустые/безымянные пары игнорируются.
    private static func parameters(from raw: String?) -> [String: String] {
        guard let raw, raw.isEmpty == false else { return [:] }
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let nameSlice = parts.first, nameSlice.isEmpty == false else { continue }
            let name = decode(String(nameSlice))
            let value = parts.count > 1 ? decode(String(parts[1])) : ""
            result[name] = value
        }
        return result
    }

    /// Percent-декодирование одного компонента (с возвратом исходной строки, если не декодируется).
    private static func decode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}
