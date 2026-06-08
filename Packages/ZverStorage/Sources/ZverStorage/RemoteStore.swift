import Foundation

/// Абстракция облачного хранилища: единственная граница между приложением и сетью.
///
/// За этим протоколом прячется любой холодный ярус — `YandexDiskStore` (REST на
/// URLSession) сейчас, Yandex Object Storage (S3) как план Б позже. Вся чистая
/// логика (очередь бэкапа, сверка sha, переходы `fileState`) работает поверх
/// `RemoteStore` и тестируется на `InMemoryRemoteStore` без сети.
///
/// Все методы асинхронны и бросают `RemoteError`. Прогресс-замыкания `@Sendable`:
/// они вызываются с сетевой очереди реализации, поэтому потребитель сам прыгает на
/// `MainActor`/каталог для записи состояния. Пути — относительные, без префикса
/// `app:/` (его подставляет адаптер).
public protocol RemoteStore: Sendable {
    /// Проверяет наличие ресурса по пути. `nil` — ресурса нет; иначе метаданные
    /// (в т.ч. `sha256` для сверки контрольной суммы).
    func exists(path: String) async throws -> RemoteResource?

    /// Перечисляет ресурсы непосредственно внутри папки (без рекурсии).
    /// Несуществующая/пустая папка → пустой массив.
    func list(folder: String) async throws -> [RemoteResource]

    /// Идемпотентно создаёт папку (и нужные родительские) по пути. Повтор — no-op.
    func ensureFolder(path: String) async throws

    /// Загружает локальный файл в облако по пути. Возвращает метаданные созданного
    /// ресурса (с облачным `sha256` и `size`). `progress` получает накопленное число
    /// отправленных байт.
    func upload(
        localFile: URL,
        to path: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource

    /// Скачивает ресурс из облака в локальный файл, докачивая с `resumeFrom`
    /// (число уже лежащих в `localFile` байт; `0` — заново). Возвращает метаданные
    /// скачанного ресурса. `progress` получает накопленное число записанных байт.
    func download(
        path: String,
        to localFile: URL,
        resumeFrom: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> RemoteResource

    /// Удаляет ресурс по пути. Отсутствие ресурса — не ошибка (идемпотентность).
    func delete(path: String) async throws
}
