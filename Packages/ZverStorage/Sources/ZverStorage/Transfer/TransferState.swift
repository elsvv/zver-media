import Foundation

/// Стадия одной передачи (выгрузки или загрузки) в ``BackupQueue``.
///
/// Эмитится планировщиком как пара `(itemId, TransferState)`; потребитель (S4-10
/// `BackupService`) мапит её в каталожный `fileState`: `transferring` → `uploading`/
/// `downloading`, `done` → сверка sha → `backedUp`, `failed` → откат в исходное.
/// `Equatable` — для точных проверок в тестах и дедупа событий.
public enum TransferState: Sendable, Equatable {
    /// Задача принята в очередь, ещё не стартовала.
    case queued
    /// Запрашивается временный href передачи (двухэтапная схема Яндекса).
    /// В `InMemoryRemoteStore` стадия мгновенная, но в модели присутствует ради
    /// зеркалирования реального жизненного цикла адаптера.
    case requestingHref
    /// Идёт передача байт; `bytesSent` — накопленный объём (для прогресс-бара).
    case transferring(bytesSent: Int64)
    /// Передача завершена, идёт сверка облачного sha с ожидаемым.
    case verifying
    /// Успех: ресурс в облаке подтверждён (несёт облачный `sha256`/`size`).
    case done(RemoteResource)
    /// Провал: ошибка и номер попытки, на которой остановились (нумерация с 1).
    case failed(RemoteError, attempt: Int)

    /// `true` для финальных стадий (`done`/`failed`), после которых задача не
    /// продолжается. Очередь использует это, чтобы освободить слот параллелизма.
    public var isTerminal: Bool {
        switch self {
        case .done, .failed:
            return true
        case .queued, .requestingHref, .transferring, .verifying:
            return false
        }
    }

    public static func == (lhs: TransferState, rhs: TransferState) -> Bool {
        switch (lhs, rhs) {
        case (.queued, .queued),
             (.requestingHref, .requestingHref),
             (.verifying, .verifying):
            return true
        case let (.transferring(a), .transferring(b)):
            return a == b
        case let (.done(a), .done(b)):
            return a == b
        case let (.failed(lError, lAttempt), .failed(rError, rAttempt)):
            return lAttempt == rAttempt && remoteErrorsEqual(lError, rError)
        default:
            return false
        }
    }
}

/// Описание одной задачи выгрузки для ``BackupQueue``.
///
/// `id` — стабильный ключ дедупа (relativePath трека в каталоге); повторный enqueue
/// с тем же `id` игнорируется, пока задача не завершилась. `expectedSha` — локальный
/// SHA-256 файла: если задан, после выгрузки облачный sha сверяется с ним (гейт
/// `backedUp`); `nil` — сверка пропускается.
public struct BackupItem: Sendable, Equatable {
    /// Стабильный идентификатор задачи (ключ дедупа).
    public let id: String
    /// Локальный файл-источник.
    public let localFile: URL
    /// Целевой путь в облаке (без префикса `app:/`).
    public let remotePath: String
    /// Ожидаемый SHA-256 контента для сверки после выгрузки; `nil` — без сверки.
    public let expectedSha: String?
    /// Размер файла в байтах (для прогресса/диагностики).
    public let fileSize: Int64

    public init(id: String, localFile: URL, remotePath: String, expectedSha: String?, fileSize: Int64) {
        self.id = id
        self.localFile = localFile
        self.remotePath = remotePath
        self.expectedSha = expectedSha
        self.fileSize = fileSize
    }
}

/// Структурное сравнение ``RemoteError`` для `Equatable`-нужд ``TransferState``.
///
/// `RemoteError` не `Equatable` (несёт `any Error` в `.transport`), но для тестов и
/// дедупа событий достаточно сравнить кейсы и их полезную нагрузку; `.transport`
/// считаем равным по самому факту кейса (underlying-ошибки не сравниваем).
func remoteErrorsEqual(_ lhs: RemoteError, _ rhs: RemoteError) -> Bool {
    switch (lhs, rhs) {
    case (.unauthorized, .unauthorized),
         (.notFound, .notFound),
         (.conflict, .conflict),
         (.locked, .locked),
         (.insufficientStorage, .insufficientStorage),
         (.badResponse, .badResponse),
         (.transport, .transport):
        return true
    case let (.rateLimited(a), .rateLimited(b)):
        return a == b
    case let (.server(a), .server(b)):
        return a == b
    default:
        return false
    }
}
