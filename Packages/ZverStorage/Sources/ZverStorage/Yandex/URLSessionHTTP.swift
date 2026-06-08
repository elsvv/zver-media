import Foundation

/// Тонкая абстракция трёх HTTP-операций, нужных адаптеру Яндекс.Диска: запрос с
/// телом-в-памяти, выгрузка файла телом PUT и потоковая выгрузка тела ответа в файл.
///
/// За протоколом прячется ЕДИНСТВЕННЫЙ рантайм-объект `URLSession` — чтобы
/// `YandexDiskStore` (чистый по структуре оркестратор «токен → запрос → разбор»)
/// можно было рассуждать против контракта, а сетевую часть проверял владелец на
/// устройстве. Тестами не покрываем (лессон прошлых этапов: рантайм-сетевые объекты
/// за протоколами). Все методы `@Sendable`-совместимы: реализация (`URLSessionHTTPClient`)
/// безопасна для вызова из любой задачи.
public protocol HTTPClient: Sendable {
    /// Выполняет запрос, тело ответа читается целиком в память.
    /// Для лёгких ответов (href, метаданные, статус операции, ошибки).
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Выполняет PUT/POST, отправляя тело из файла `fileURL` (без чтения целиком в
    /// память — hi-res файлы это сотни МБ). Тело ответа — в память (мало).
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)

    /// Выполняет GET, дописывая тело ответа в `destination`. Если `append == true`
    /// (докачка, сервер ответил 206) — дозапись в конец существующего префикса; иначе
    /// (`200`/новый файл) — перезапись с нуля. `progress` зовётся с накопленным числом
    /// байт НА ДИСКЕ. Возвращает HTTP-ответ (статус решает append vs overwrite —
    /// см. `YandexDiskStore.download`).
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse
}

/// Боевой `HTTPClient` поверх `URLSession`.
///
/// Сессия инъецируется (конфигурируемая): по умолчанию — `.default`; для переживания
/// сворачивания приложения предусмотрен фабричный `background(identifier:)`-вариант.
/// `@unchecked Sendable` оправдан: `URLSession` потокобезопасна, собственного
/// мутабельного состояния у клиента нет.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    /// - Parameter session: сессия выполнения. Дефолт — `.shared`-эквивалент с
    ///   `.default`-конфигом (можно подменить фоновой через ``background(identifier:)``).
    public init(session: URLSession = URLSession(configuration: .default)) {
        self.session = session
    }

    /// Фабрика фоновой сессии для докачки при свёрнутом/убитом приложении.
    ///
    /// `delegate`/`delegateQueue` оставлены дефолтными: высокоуровневый async-API
    /// (`data`/`upload`/`download`) обслуживается системой и резюмит continuation.
    /// Полноценная фоновая доставка через делегат — задача интеграции (S4-10), здесь
    /// предоставляется лишь конфигурируемая точка.
    public static func background(identifier: String) -> URLSessionHTTPClient {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSessionHTTPClient(session: URLSession(configuration: config))
    }

    // MARK: - HTTPClient

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.badResponse
        }
        return (data, http)
    }

    public func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.badResponse
        }
        return (data, http)
    }

    public func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> HTTPURLResponse {
        let (tempURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteError.badResponse
        }

        let fm = FileManager.default
        // 206 (Partial Content) → сервер отдал ХВОСТ от запрошенного Range:
        // дописываем его в конец уже лежащего префикса. Иначе (200/новый файл) —
        // материализуем целиком с нуля.
        let append = http.statusCode == 206 && fm.fileExists(atPath: destination.path)
        if append {
            let tailHandle = try FileHandle(forReadingFrom: tempURL)
            defer { try? tailHandle.close() }
            let outHandle = try FileHandle(forWritingTo: destination)
            defer { try? outHandle.close() }
            try outHandle.seekToEnd()
            while true {
                let chunk = try tailHandle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty { break }
                try outHandle.write(contentsOf: chunk)
            }
        } else {
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tempURL, to: destination)
        }

        let finalSize = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)??.int64Value ?? 0
        progress(finalSize)
        return http
    }
}
