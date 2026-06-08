import Foundation

/// Статус async-операции Яндекс.Диска (напр. перманентного удаления).
///
/// При 202-ответе сервер даёт href операции; поллинг по нему возвращает один из
/// этих статусов (поле `status` в JSON: `in-progress`/`success`/`failed`).
public enum OperationStatus: Sendable, Equatable {
    case inProgress
    case success
    case failed
}

/// Разобранное тело ошибки Яндекс REST.
///
/// Не влияет на классификацию (её определяет HTTP-статус, см. ``YandexError``),
/// но несёт человекочитаемое описание для логов/UI и машинный код `error`
/// (напр. `DiskNotFoundError`).
public struct YandexErrorBody: Sendable, Equatable {
    /// Локализованное сообщение Яндекса.
    public let message: String?
    /// Английское описание.
    public let description: String?
    /// Машинный код ошибки (`error` в JSON).
    public let error: String?

    public init(message: String?, description: String?, error: String?) {
        self.message = message
        self.description = description
        self.error = error
    }
}

/// Чистые парсеры JSON-ответов Яндекс.Диск REST из сырых `Data`.
///
/// Все методы статические и не делают сети — на них ведётся TDD на литералах.
/// Нераспознанные ответы → `RemoteError.badResponse` (`parseErrorBody` —
/// исключение: возвращает `nil`, т.к. вызывается, когда уже известно, что ответ
/// ошибочный, и тело может быть произвольным).
public enum YandexResponse {
    // MARK: - href

    /// Извлекает `href` из ответа `{ href, method, templated }` запроса
    /// upload/download-ссылки. Отсутствие `href`/битый URL → `.badResponse`.
    public static func parseHref(_ data: Data) throws -> URL {
        let dto = try decode(HrefDTO.self, from: data)
        guard let url = URL(string: dto.href) else {
            throw RemoteError.badResponse
        }
        return url
    }

    // MARK: - ресурс / список

    /// Разбирает метаданные одного ресурса (`ResourceMeta`) в ``RemoteResource``.
    ///
    /// Директория определяется по `type == "dir"` (у неё `size == 0`, `sha256 == nil`).
    /// `path` нормализуется: префикс хранилища (`app:/`, `disk:/...`) срезается,
    /// чтобы `RemoteResource.path` был зеркалом локального относительного пути.
    public static func parseResource(_ data: Data) throws -> RemoteResource {
        let dto = try decode(ResourceDTO.self, from: data)
        return resource(from: dto)
    }

    /// Разбирает список содержимого папки из `_embedded.items`.
    ///
    /// Если `_embedded` отсутствует (ответ на файл, а не папку) или `items` пуст —
    /// возвращает пустой массив (а не ошибку): пустая/несуществующая папка → `[]`.
    public static func parseList(_ data: Data) throws -> [RemoteResource] {
        let dto = try decode(ResourceDTO.self, from: data)
        guard let items = dto._embedded?.items else {
            return []
        }
        return items.map(resource(from:))
    }

    // MARK: - операция

    /// Разбирает статус async-операции (`{ "status": "..." }`). Неизвестный статус
    /// → `.badResponse`.
    public static func parseOperation(_ data: Data) throws -> OperationStatus {
        let dto = try decode(OperationDTO.self, from: data)
        switch dto.status {
        case "in-progress":
            return .inProgress
        case "success":
            return .success
        case "failed":
            return .failed
        default:
            throw RemoteError.badResponse
        }
    }

    // MARK: - тело ошибки

    /// Лучшая попытка разобрать тело ошибки. Возвращает `nil`, если это не
    /// ошибочное тело (нет ни одного из полей `message`/`description`/`error`).
    public static func parseErrorBody(_ data: Data) -> YandexErrorBody? {
        guard let dto = try? JSONDecoder().decode(ErrorBodyDTO.self, from: data) else {
            return nil
        }
        if dto.message == nil, dto.description == nil, dto.error == nil {
            return nil
        }
        return YandexErrorBody(message: dto.message, description: dto.description, error: dto.error)
    }

    // MARK: - Внутреннее

    /// Декодирует тип, оборачивая любой сбой парсинга в `RemoteError.badResponse`.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RemoteError.badResponse
        }
    }

    /// Конструирует ``RemoteResource`` из DTO ресурса.
    private static func resource(from dto: ResourceDTO) -> RemoteResource {
        let isDir = dto.type == "dir"
        return RemoteResource(
            path: strippedPath(dto.path, name: dto.name),
            name: dto.name,
            size: isDir ? 0 : (dto.size ?? 0),
            sha256: isDir ? nil : dto.sha256,
            isDir: isDir
        )
    }

    /// Срезает префикс пространства имён диска (`app:/`, `disk:/...`) с пути ресурса.
    ///
    /// Яндекс возвращает `path` вида `app:/library/album/track.flac`; нам нужен
    /// относительный `library/album/track.flac`. Если `path` отсутствует —
    /// фоллбэк на имя.
    private static func strippedPath(_ path: String?, name: String) -> String {
        guard let path else { return name }
        // Срезаем всё до первого "/" после схемы "<ns>:/" → берём остаток.
        if let range = path.range(of: ":/") {
            var rest = String(path[range.upperBound...])
            while rest.hasPrefix("/") {
                rest.removeFirst()
            }
            return rest
        }
        var p = path
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        return p
    }
}

// MARK: - DTO (форма JSON Яндекса)

private struct HrefDTO: Decodable {
    let href: String
}

private struct ResourceDTO: Decodable {
    let name: String
    let path: String?
    let type: String?
    let size: Int64?
    let sha256: String?
    let md5: String?
    let _embedded: EmbeddedDTO?
}

private struct EmbeddedDTO: Decodable {
    let items: [ResourceDTO]?
}

private struct OperationDTO: Decodable {
    let status: String
}

private struct ErrorBodyDTO: Decodable {
    let message: String?
    let description: String?
    let error: String?
}
