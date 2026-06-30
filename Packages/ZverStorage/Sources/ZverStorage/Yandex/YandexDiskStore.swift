import Foundation

/// `RemoteStore` поверх Яндекс.Диск REST API на `URLSession`.
///
/// Единственный РАНТАЙМ-объект storage-слоя: всё остальное (фабрика запросов, разбор
/// ответов и ошибок, очередь, backoff) — чистое и под TDD. Сам адаптер тонкий —
/// «токен → ``YandexRequestFactory`` собирает запрос → ``HTTPClient`` выполняет →
/// ``YandexResponse``/``YandexError`` разбирают». Тестами НЕ покрывается (лессон
/// прошлых этапов: рантайм-сетевые объекты за протоколами проверяет владелец на
/// устройстве); проверка — компиляция пакета и зелёные чистые тесты.
///
/// **Одиночная попытка.** Методы НЕ ретраят сами — при ретраябельной ошибке бросают
/// `RemoteError`, а повторы (классификация + backoff) живут в ``BackupQueue`` (S4-4),
/// чтобы не дублировать политику. Инъецированная ``RetryPolicy`` хранится для
/// единственного внутреннего исключения — поллинга async-операции удаления (короткий
/// фиксированный цикл, см. ``delete(path:)``).
///
/// **Двухэтапность.** `upload`/`download` сперва берут временный href
/// (`uploadHref`/`downloadHref`), затем PUT/GET тела на него. Скачивание докачивает
/// через `Range: bytes=<resumeFrom>-` (зеркало `FileDownloader` этапа 3). Резюм
/// АПЛОАДА — best-effort: при обрыве вызывающий заново запрашивает href и PUT
/// (ограничение задокументировано в плане; докачка СКАЧИВАНИЯ — полноценная).
///
/// Делегатские/прогресс-колбэки `@Sendable`: приходят с сетевой очереди, потребитель
/// сам прыгает на `MainActor`/каталог. `@unchecked Sendable` оправдан: все хранимые
/// поля — `Sendable`-значения, собственного мутабельного состояния нет.
public final class YandexDiskStore: RemoteStore, @unchecked Sendable {
    private let http: HTTPClient
    private let factory: YandexRequestFactory
    private let tokenProvider: any TokenProviding
    private let policy: RetryPolicy

    /// Набор полей метаданных, запрашиваемых у `/resources` (size/sha256 для сверки,
    /// `_embedded.items` для листинга папки).
    private static let resourceFields =
        "name,path,type,size,sha256,md5,_embedded.items.name,_embedded.items.path,"
        + "_embedded.items.type,_embedded.items.size,_embedded.items.sha256,_embedded.items.md5"

    /// - Parameters:
    ///   - http: HTTP-клиент (боевой ``URLSessionHTTPClient``, в т.ч. фоновая сессия).
    ///   - factory: фабрика запросов (несёт базу API и префикс `app:/`).
    ///   - tokenProvider: поставщик OAuth-токена (инъекция — стор не хранит креды).
    ///   - policy: политика повторов; используется ТОЛЬКО для поллинга async-удаления
    ///     (передачи ретраит ``BackupQueue``, не адаптер).
    public init(
        http: HTTPClient,
        factory: YandexRequestFactory,
        tokenProvider: any TokenProviding,
        policy: RetryPolicy = RetryPolicy()
    ) {
        self.http = http
        self.factory = factory
        self.tokenProvider = tokenProvider
        self.policy = policy
    }

    /// Удобный инициализатор поверх боевой URLSession-обёртки и стандартной базы API.
    ///
    /// - Parameters:
    ///   - baseURL: база Disk REST API (дефолт — `https://cloud-api.yandex.net/v1/disk`).
    ///   - rootPrefix: префикс пространства имён (дефолт — `app:/`, app-folder scope).
    ///   - tokenProvider: поставщик токена.
    ///   - session: URLSession (дефолт — `.default`; для фона — ``URLSessionHTTPClient/background(identifier:)``).
    public convenience init(
        baseURL: URL = URL(string: "https://cloud-api.yandex.net/v1/disk")!,
        rootPrefix: String = "app:/",
        tokenProvider: any TokenProviding,
        session: URLSession = URLSession(configuration: .default),
        policy: RetryPolicy = RetryPolicy()
    ) {
        self.init(
            http: URLSessionHTTPClient(session: session),
            factory: YandexRequestFactory(baseURL: baseURL, rootPrefix: rootPrefix),
            tokenProvider: tokenProvider,
            policy: policy
        )
    }

    // MARK: - RemoteStore

    public func exists(path: String) async throws -> RemoteResource? {
        let request = factory.resourceMeta(path: path, fields: Self.resourceFields)
        let (data, http) = try await send(request)
        if http.statusCode == 404 {
            return nil
        }
        try ensureSuccess(http, data: data)
        return try YandexResponse.parseResource(data)
    }

    public func list(folder: String) async throws -> [RemoteResource] {
        let request = factory.resourceMeta(path: folder, fields: Self.resourceFields)
        let (data, http) = try await send(request)
        // Несуществующая папка → пустой список (а не ошибка): зеркало `InMemoryRemoteStore`.
        if http.statusCode == 404 {
            return []
        }
        try ensureSuccess(http, data: data)
        return try YandexResponse.parseList(data)
    }

    public func ensureFolder(path: String) async throws {
        // Яндекс.Диск `createFolder` создаёт ТОЛЬКО лист — родитель должен
        // существовать. Для вложенного пути (`zver-media/library/<albumId>`)
        // поднимаемся от корня и создаём каждый сегмент по очереди. 201 (создана)
        // и 409 (уже есть) — оба успех (идемпотентность).
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return }
        var cumulative = ""
        for segment in segments {
            cumulative = cumulative.isEmpty ? segment : "\(cumulative)/\(segment)"
            let request = factory.createFolder(path: cumulative)
            let (data, http) = try await send(request)
            if http.statusCode == 201 || http.statusCode == 409 {
                continue
            }
            try ensureSuccess(http, data: data)
        }
    }

    public func upload(
        localFile: URL,
        to path: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        // Этап 1: получить временный href для PUT.
        let hrefRequest = factory.uploadHref(path: path)
        let (hrefData, hrefHTTP) = try await send(hrefRequest)
        try ensureSuccess(hrefHTTP, data: hrefData)
        let href = try YandexResponse.parseHref(hrefData)

        // Этап 2: PUT тела файла на href (без авторизации — href самодостаточен).
        let putRequest = factory.transfer(href: href, method: "PUT", range: nil)
        let (putData, putHTTP) = try await http.upload(putRequest, fromFile: localFile)
        try ensureSuccess(putHTTP, data: putData)

        // Прогресс: PUT шлёт тело целиком — репортим финальный размер файла.
        let size = fileSize(localFile)
        progress(size)

        // Облачные метаданные (sha256 для сверки) появляются не моментально — читаем мету.
        return try await resourceAfterTransfer(path: path, fallbackSize: size)
    }

    public func download(
        path: String,
        to localFile: URL,
        resumeFrom: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource {
        // Этап 1: получить временный href для GET.
        let hrefRequest = factory.downloadHref(path: path)
        let (hrefData, hrefHTTP) = try await send(hrefRequest)
        try ensureSuccess(hrefHTTP, data: hrefData)
        let href = try YandexResponse.parseHref(hrefData)

        // Этап 2: GET тела на href с докачкой через Range (зеркало FileDownloader).
        let getRequest = factory.transfer(href: href, method: "GET", range: resumeFrom > 0 ? resumeFrom : nil)
        let getHTTP = try await http.download(getRequest, to: localFile, progress: progress)
        try ensureSuccess(getHTTP, data: Data())

        // Метаданные (включая sha256) — отдельным запросом меты ресурса.
        return try await resourceAfterTransfer(path: path, fallbackSize: fileSize(localFile))
    }

    public func delete(path: String) async throws {
        let request = factory.delete(path: path, permanently: true)
        let (data, http) = try await send(request)
        switch http.statusCode {
        case 204:
            return // синхронное удаление
        case 404:
            return // уже нет — идемпотентность
        case 202:
            // Async-операция: поллим её href до завершения коротким циклом.
            try await pollDeletion(operationData: data)
        default:
            try ensureSuccess(http, data: data)
        }
    }

    // MARK: - Внутреннее

    /// Подставляет токен (или бросает `unauthorized`, если не залогинен) и выполняет
    /// запрос. Транспортные сбои оборачиваются в `RemoteError.transport`.
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let token = await tokenProvider.token() else {
            throw RemoteError.unauthorized
        }
        let authorized = factory.authorized(request, token: token)
        do {
            return try await http.data(for: authorized)
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError.transport(underlying: error)
        }
    }

    /// Бросает маппинг `YandexError`, если статус не 2xx. На 2xx — no-op.
    private func ensureSuccess(_ http: HTTPURLResponse, data: Data) throws {
        guard !(200...299).contains(http.statusCode) else { return }
        throw YandexError.from(
            status: http.statusCode,
            data: data,
            headers: headerDictionary(http)
        )
    }

    /// Читает метаданные ресурса после успешной передачи (для облачного `sha256`).
    /// Если мета почему-то недоступна — отдаёт минимальный ресурс по известному
    /// размеру (sha остаётся `nil`, сверку выполнит вызывающий, увидев несовпадение).
    private func resourceAfterTransfer(path: String, fallbackSize: Int64) async throws -> RemoteResource {
        if let resource = try? await exists(path: path), resource.isDir == false {
            return resource
        }
        return RemoteResource(
            path: path,
            name: lastComponent(path),
            size: fallbackSize,
            sha256: nil,
            isDir: false
        )
    }

    /// Поллит async-операцию удаления по её href до `success`/`failed` либо до
    /// исчерпания попыток. Использует ``RetryPolicy`` лишь как источник числа попыток
    /// и пауз между опросами (это НЕ ретрай передачи — это ожидание async-операции).
    private func pollDeletion(operationData: Data) async throws {
        let href = try YandexResponse.parseHref(operationData)
        var attempt = 0
        while policy.shouldRetry(attempt: attempt + 1) {
            attempt += 1
            let request = factory.operationStatus(href: href)
            let (data, http) = try await send(request)
            try ensureSuccess(http, data: data)
            switch try YandexResponse.parseOperation(data) {
            case .success:
                return
            case .failed:
                throw RemoteError.badResponse
            case .inProgress:
                let nanos = UInt64((policy.delay(forAttempt: attempt, retryAfter: nil) * 1_000_000_000).rounded())
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        // Операция не завершилась за отведённые попытки — считаем удаление успешным
        // best-effort (повторное удаление позже идемпотентно).
    }

    /// Преобразует заголовки `HTTPURLResponse` в `[String: String]` для `YandexError`.
    private func headerDictionary(_ http: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                result[k] = v
            }
        }
        return result
    }

    /// Размер локального файла в байтах (0, если файла нет/недоступен).
    private func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
