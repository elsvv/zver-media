import Foundation

/// Маппинг между путями каталога/ФС телефона и путями на Яндекс.Диске.
///
/// Локальная раскладка: `Documents/Library/<albumId>/<fileName>` — `relativePath`
/// трека в каталоге (относительно Documents) имеет вид `Library/<albumId>/<fileName>`
/// (с заглавной `L`). Облачная раскладка (раздел «Раскладка на Яндекс.Диске» плана
/// этапа 4) — зеркало с НИЖНИМ регистром корня:
/// ```
/// app:/                                  (= префикс YandexDiskStore)
///   catalog.sqlite.backup                бэкап каталога
///   library/<albumId>/<fileName>         аудиофайлы
/// ```
/// `RemoteStore` принимает пути БЕЗ префикса `app:/` — его подставляет адаптер.
/// Поэтому `CloudPaths` отдаёт `library/<albumId>/<fileName>` и `catalog.sqlite.backup`.
///
/// Чистая трансформация строк (никакой сети/ФС) — живёт в app-слое, потому что
/// оперирует и каталожным `relativePath` (`ZverCore`), и облачным путём (`ZverStorage`),
/// которые друг о друге не знают. Проверяется компиляцией.
enum CloudPaths {
    /// Корневая папка библиотеки в каталоге (`relativePath`-префикс, заглавная `L`).
    static let localLibraryPrefix = "Library/"
    /// Корневая папка библиотеки в облаке (нижний регистр, без префикса `app:/`).
    static let remoteLibraryRoot = "library"
    /// Имя бэкапа каталога в корне облака.
    static let catalogBackupName = "catalog.sqlite.backup"

    /// Облачный путь файла трека по его каталожному `relativePath`.
    ///
    /// `Library/<albumId>/<fileName>` → `library/<albumId>/<fileName>`. Если путь
    /// не начинается с `Library/` (нетипично — трек вне библиотеки), кладём его как
    /// есть под `library/`, чтобы маппинг оставался обратимым и не терял файлы.
    static func remotePath(forRelativePath relativePath: String) -> String {
        let suffix: String
        if relativePath.hasPrefix(localLibraryPrefix) {
            suffix = String(relativePath.dropFirst(localLibraryPrefix.count))
        } else {
            // Уберём ведущий слэш, если есть, и положим под library/.
            suffix = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        }
        return "\(remoteLibraryRoot)/\(suffix)"
    }

    /// Каталожный `relativePath` по облачному пути (обратное к `remotePath`).
    ///
    /// `library/<albumId>/<fileName>` → `Library/<albumId>/<fileName>`. Используется
    /// при скачивании, чтобы по облачному пути восстановить локальное размещение.
    static func relativePath(forRemotePath remotePath: String) -> String {
        let trimmed = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
        let rootSlash = "\(remoteLibraryRoot)/"
        if trimmed.hasPrefix(rootSlash) {
            return localLibraryPrefix + String(trimmed.dropFirst(rootSlash.count))
        }
        return trimmed
    }

    /// Локальный URL файла трека по его каталожному `relativePath`.
    static func localURL(forRelativePath relativePath: String, documentsURL: URL) -> URL {
        documentsURL.appendingPathComponent(relativePath)
    }

    /// Каталожный `relativePath` по локальному URL файла (относительно Documents).
    /// `nil`, если URL вне Documents (не должно случаться для треков библиотеки).
    static func relativePath(of url: URL, documentsURL: URL) -> String? {
        let basePath = documentsURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath + "/") else { return nil }
        return String(path.dropFirst(basePath.count + 1))
    }
}
