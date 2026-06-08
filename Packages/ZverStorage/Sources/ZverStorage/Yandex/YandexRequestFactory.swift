import Foundation

/// Чистая сборка `URLRequest` для эндпоинтов Яндекс.Диск REST.
///
/// Ни один метод не выполняет запрос — только конструирует его. Это позволяет
/// TDD-ровать форму запросов (URL, метод, query, заголовки) на литералах без сети.
/// Токен авторизации НЕ участвует в основных методах (чтобы не светить его в
/// фикстурах) — он подставляется отдельно через ``authorized(_:token:)`` уже
/// рантайм-адаптером (`YandexDiskStore`, S4-5).
///
/// Относительные пути (`library/<albumId>/<fileName>`, `catalog.sqlite.backup`)
/// маппятся в полный путь хранилища с префиксом ``rootPrefix`` (`app:/` для
/// app-folder scope) и percent-кодируются. Базовый префикс — настройка, чтобы
/// план Б (полный Диск без app-folder) менял только конструктор адаптера.
///
/// База API: `https://cloud-api.yandex.net/v1/disk` (передаётся в ``init(baseURL:rootPrefix:)``).
public struct YandexRequestFactory: Sendable {
    /// База Disk REST API, напр. `https://cloud-api.yandex.net/v1/disk`.
    private let baseURL: URL
    /// Префикс пространства имён диска, напр. `app:/` (app-folder scope).
    private let rootPrefix: String

    public init(baseURL: URL, rootPrefix: String) {
        self.baseURL = baseURL
        self.rootPrefix = rootPrefix
    }

    // MARK: - Двухэтапные ссылки (href)

    /// `GET /resources/upload?path=<p>&overwrite=true` — запрос временного href
    /// для PUT-заливки файла (двухэтапный аплоад).
    public func uploadHref(path: String) -> URLRequest {
        var request = resourcesRequest(
            subpath: "/resources/upload",
            method: "GET",
            extraQuery: [
                URLQueryItem(name: "path", value: diskPath(path)),
                URLQueryItem(name: "overwrite", value: "true"),
            ]
        )
        request.httpMethod = "GET"
        return request
    }

    /// `GET /resources/download?path=<p>` — запрос временного href для GET-скачивания.
    public func downloadHref(path: String) -> URLRequest {
        resourcesRequest(
            subpath: "/resources/download",
            method: "GET",
            extraQuery: [URLQueryItem(name: "path", value: diskPath(path))]
        )
    }

    // MARK: - Метаданные / список

    /// `GET /resources?path=<p>&fields=<...>` — метаданные ресурса (exists/list/сверка sha).
    ///
    /// `fields` ограничивает набор полей ответа (включая `_embedded.items...` для
    /// списка содержимого папки). `nil` → query `fields` не добавляется.
    public func resourceMeta(path: String, fields: String?) -> URLRequest {
        var query = [URLQueryItem(name: "path", value: diskPath(path))]
        if let fields {
            query.append(URLQueryItem(name: "fields", value: fields))
        }
        return resourcesRequest(subpath: "/resources", method: "GET", extraQuery: query)
    }

    // MARK: - Удаление / создание папки

    /// `DELETE /resources?path=<p>&permanently=<bool>` — удаление ресурса.
    /// Ответ — 204 (синхронно) либо 202 + href операции (async, поллинг).
    public func delete(path: String, permanently: Bool) -> URLRequest {
        resourcesRequest(
            subpath: "/resources",
            method: "DELETE",
            extraQuery: [
                URLQueryItem(name: "path", value: diskPath(path)),
                URLQueryItem(name: "permanently", value: permanently ? "true" : "false"),
            ]
        )
    }

    /// `PUT /resources?path=<p>` — создание папки (201). Конфликт (уже есть) — 409.
    public func createFolder(path: String) -> URLRequest {
        resourcesRequest(
            subpath: "/resources",
            method: "PUT",
            extraQuery: [URLQueryItem(name: "path", value: diskPath(path))]
        )
    }

    // MARK: - Поллинг async-операции

    /// `GET <operation href>` — статус ранее запущенной async-операции (напр. удаления).
    /// href приходит абсолютным в ответе 202 — выполняем по нему без перекодирования.
    public func operationStatus(href: URL) -> URLRequest {
        var request = URLRequest(url: href)
        request.httpMethod = "GET"
        return request
    }

    // MARK: - Передача тела на временный href

    /// Запрос передачи тела на временный href: PUT (аплоад) либо GET (скачивание).
    ///
    /// href уже абсолютный (из ``uploadHref(path:)`` / ``downloadHref(path:)``) —
    /// используем как есть. Для докачки скачивания `range` задаёт смещение в байтах
    /// уже лежащего префикса → заголовок `Range: bytes=<range>-`. `nil` или `0` —
    /// без заголовка `Range`.
    public func transfer(href: URL, method: String, range: Int64?) -> URLRequest {
        var request = URLRequest(url: href)
        request.httpMethod = method
        if let range, range > 0 {
            request.setValue("bytes=\(range)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    // MARK: - Авторизация

    /// Возвращает копию запроса с добавленным заголовком `Authorization: OAuth <token>`.
    ///
    /// Не мутирует оригинал — токен подставляется поздно, чтобы фабрика и её тесты
    /// никогда не держали секрет. Прочие заголовки (`Range`) сохраняются.
    public func authorized(_ request: URLRequest, token: String) -> URLRequest {
        var copy = request
        copy.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        return copy
    }

    // MARK: - Внутреннее

    /// Собирает запрос к `baseURL + subpath` с query-компонентами.
    private func resourcesRequest(
        subpath: String,
        method: String,
        extraQuery: [URLQueryItem]
    ) -> URLRequest {
        let endpoint = baseURL.appendingPathComponent(subpath)
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = extraQuery
        // URLComponents кодирует значения query сам (пробелы → %20, кириллица → %D0..),
        // но НЕ кодирует "+" в значении (в query "+" допустим и означает себя). Это
        // безопасно: Яндекс читает декодированный path, а "+" в path-значении query —
        // литеральный плюс. Для надёжности добавляем "+" в множество "опасных" вручную.
        if let raw = comps.percentEncodedQuery {
            comps.percentEncodedQuery = raw.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        return request
    }

    /// Маппит относительный путь (`library/...`) в полный путь хранилища
    /// (`app:/library/...`), нормализуя ведущий слэш.
    private func diskPath(_ relative: String) -> String {
        var p = relative
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        // rootPrefix вида "app:/" уже заканчивается слэшем; "disk:/Zver" — нет.
        if rootPrefix.hasSuffix("/") {
            return rootPrefix + p
        } else {
            return rootPrefix + "/" + p
        }
    }
}
