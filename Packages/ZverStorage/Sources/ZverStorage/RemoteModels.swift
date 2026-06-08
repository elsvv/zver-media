import Foundation

/// Метаданные ресурса в облаке: файла или директории.
///
/// Возвращается из всех методов `RemoteStore`, читающих/записывающих облако
/// (`exists`/`list`/`upload`/`download`). `sha256` — отпечаток контента,
/// которым гейтится удаление локальной копии (offload разрешён только когда
/// облачный sha совпал с локальным). У директорий `sha256 == nil`, `size == 0`.
public struct RemoteResource: Sendable, Equatable, Codable {
    /// Путь ресурса относительно корня хранилища (без префикса `app:/`),
    /// напр. `library/<albumId>/<fileName>`.
    public let path: String
    /// Имя ресурса (последний компонент пути).
    public let name: String
    /// Размер в байтах. Для директорий — `0`.
    public let size: Int64
    /// SHA-256 контента в нижнем регистре hex, если известен. `nil` у директорий
    /// и у источников без метаданных контрольной суммы.
    public let sha256: String?
    /// `true`, если ресурс — директория.
    public let isDir: Bool

    public init(path: String, name: String, size: Int64, sha256: String?, isDir: Bool) {
        self.path = path
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.isDir = isDir
    }
}

/// Описание одной выгрузки: что и куда загрузить.
///
/// Тонкая пара «локальный файл → удалённый путь», на которой строит свои
/// `BackupItem` планировщик очереди (S4-4) и `BackupService` приложения.
public struct UploadTarget: Sendable, Equatable {
    /// Локальный файл-источник.
    public let localFile: URL
    /// Целевой путь в облаке (без префикса `app:/`).
    public let remotePath: String

    public init(localFile: URL, remotePath: String) {
        self.localFile = localFile
        self.remotePath = remotePath
    }
}

/// Описание одной загрузки: откуда, куда и с какого смещения докачивать.
public struct DownloadTarget: Sendable, Equatable {
    /// Путь источника в облаке (без префикса `app:/`).
    public let remotePath: String
    /// Локальный файл-приёмник (staging-файл, потом атомарно переезжает в библиотеку).
    public let localFile: URL
    /// Смещение докачки в байтах: сколько уже лежит в `localFile`. `0` — качать заново.
    public let resumeFrom: Int64

    public init(remotePath: String, localFile: URL, resumeFrom: Int64 = 0) {
        self.remotePath = remotePath
        self.localFile = localFile
        self.resumeFrom = resumeFrom
    }
}

/// Словарь ошибок облака — общий для всех реализаций `RemoteStore`.
///
/// Реализации (`YandexDiskStore`, `InMemoryRemoteStore`) маппят свои низкоуровневые
/// сбои в эти кейсы; `RetryPolicy` (S4-3) классифицирует их на ретраябельные/
/// фатальные, а UI — показывает понятную причину. Намеренно НЕ привязан к Яндексу,
/// чтобы план Б (S3) лёг за тот же протокол.
public enum RemoteError: Error, Sendable {
    /// Токен битый/просрочен (HTTP 401). Фатально — нужен перелогин.
    case unauthorized
    /// Ресурса нет (HTTP 404). Фатально.
    case notFound
    /// Конфликт: нет родительской папки, уже существует и т.п. (HTTP 409). Фатально.
    case conflict
    /// Ресурс заблокирован операцией (HTTP 423). Ретраябельно с backoff.
    case locked
    /// Превышен лимит запросов (HTTP 429). Ретраябельно; `retryAfter` — секунды
    /// из заголовка `Retry-After`, если сервер их прислал.
    case rateLimited(retryAfter: TimeInterval?)
    /// Нет места в облаке (HTTP 507). Фатально — показать пользователю.
    case insufficientStorage
    /// Серверная ошибка (HTTP 5xx). Ретраябельно.
    case server(status: Int)
    /// Транспортный сбой (нет сети, таймаут, обрыв соединения). Ретраябельно.
    case transport(underlying: any Error)
    /// Ответ не распознан (неожиданный статус/тело). Фатально для одной попытки.
    case badResponse
}
