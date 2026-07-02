import Foundation
import ZverTransport

/// Снимок раздаваемого состояния Мака для файлового сервера: текущий манифест
/// исходящей очереди + резолвер «albumId/fileName → URL файла на диске» + индекс
/// sha256 (для `ETag`/`If-Range`).
///
/// `Sendable`-снимок намеренно отвязан от `@MainActor`-моделей (`OutgoingQueue`/
/// `QueuedAlbum`): сервер читает его на сетевой очереди, не наследуя UI-изоляцию.
/// Пересобирается на `@MainActor` при каждом изменении очереди и кладётся в
/// потокобезопасный держатель (`HostState`), откуда сервер берёт актуальную копию.
struct HostSnapshot: Sendable {
    /// Готовый манифест очереди (то, что отдаём по `GET /manifest`).
    let manifest: SyncManifest

    /// Раздаваемые файлы по относительному пути `"<albumId>/<fileName>"`.
    /// Значение — абсолютный URL файла-источника + его sha256 (ETag) и размер.
    let files: [String: ServedFile]

    init(manifest: SyncManifest, files: [String: ServedFile]) {
        self.manifest = manifest
        self.files = files
    }

    /// Пустой снимок (очередь пуста — раздавать нечего).
    static let empty = HostSnapshot(
        manifest: SyncManifest(albums: []),
        files: [:]
    )

    /// Один раздаваемый файл: путь на диске Мака, контент-хеш (ETag) и размер.
    struct ServedFile: Sendable {
        let url: URL
        let sha256: String
        let fileSize: Int
    }

    /// Резолвит запрос `GET /album/<albumId>/<fileName>` в файл на диске.
    /// nil — такого файла в текущей раздаче нет (→ 404).
    func file(albumId: String, fileName: String) -> ServedFile? {
        files[HostSnapshot.relativePath(albumId: albumId, fileName: fileName)]
    }

    /// Относительный путь раздачи / ключ карты файлов: `"<albumId>/<fileName>"`.
    /// Локальный (как на iOS-стороне): `SyncPlanner.relativePath` внутренний к
    /// `ZverTransport`, обе стороны протокола считают ключ одинаково.
    static func relativePath(albumId: String, fileName: String) -> String {
        "\(albumId)/\(fileName)"
    }
}

/// Потокобезопасный держатель текущего `HostSnapshot` и набора выпущенных токенов.
///
/// Сервер (`FileServer`) работает на сетевой очереди и читает отсюда снимок и
/// проверяет токены БЕЗ перехода на `@MainActor`. `@MainActor`-сторона
/// (`SyncHost`) лишь публикует новые снимки и токены. Всё мутабельное состояние
/// под `NSLock` → `@unchecked Sendable` оправдан.
final class HostState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: HostSnapshot = .empty
    /// Активные сессионные токены (доступ к `/manifest`, `/album`, `/confirm`).
    private var tokens: Set<String> = []
    /// Текущий код сопряжения, если окно pairing открыто; nil — pairing закрыт.
    private var pairingCode: String?
    /// Колбэк выпуска нового токена (успешный `POST /pair`). Вызывается на сетевой
    /// очереди ВНЕ замка; приложение внутри прыгает на `@MainActor`.
    private var onTokenIssued: (@Sendable (String) -> Void)?

    init() {}

    /// Подписывает на событие выпуска токена (сопряжение состоялось). `@Sendable`:
    /// вызывается на сетевой очереди, переход в UI/модель — на стороне подписчика.
    func setOnTokenIssued(_ handler: @escaping @Sendable (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        onTokenIssued = handler
    }

    /// Текущий раздаваемый снимок (атомарная копия).
    func currentSnapshot() -> HostSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    /// Публикует новый снимок раздачи (после изменения очереди).
    func setSnapshot(_ snapshot: HostSnapshot) {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
    }

    /// Проверяет валидность сессионного токена (`X-Zver-Token`).
    func isAuthorized(token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return tokens.contains(token)
    }

    /// Добавляет выпущенный сервером токен в набор доверенных.
    func registerToken(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        tokens.insert(token)
    }

    /// Открывает окно сопряжения с заданным кодом.
    func openPairing(code: String) {
        lock.lock(); defer { lock.unlock() }
        pairingCode = code
    }

    /// Закрывает окно сопряжения (код больше не принимается).
    func closePairing() {
        lock.lock(); defer { lock.unlock() }
        pairingCode = nil
    }

    /// Пытается сопрячься по присланному коду в открытом окне pairing.
    ///
    /// Возвращает выпущенный токен при успехе (код совпал и окно открыто), иначе
    /// nil. Сравнение кода — постоянное по времени (`Pairing.verify`). При успехе
    /// токен регистрируется и окно pairing закрывается (код одноразовый).
    func tryPair(code: String) -> String? {
        lock.lock()
        guard let expected = pairingCode, Pairing.verify(code: code, expected: expected) else {
            lock.unlock()
            return nil
        }
        pairingCode = nil
        let token = Pairing.generateToken()
        tokens.insert(token)
        let handler = onTokenIssued
        lock.unlock()
        handler?(token)
        return token
    }
}

/// `@MainActor`-связка исходящей очереди с раздаваемым состоянием сервера.
///
/// Собирает `HostSnapshot` из `OutgoingQueue` (манифест + индекс файлов с sha из
/// уже посчитанного манифеста) и публикует его в `HostState`. Обрабатывает
/// `confirm` от телефона: помечает альбом доставленным и убирает его из очереди.
/// Сетевые колбэки `FileServer` приходят сюда через `Task { @MainActor in … }`.
@MainActor
final class SyncHost {
    /// Исходящая очередь — источник правды о том, что раздаём.
    private let queue: OutgoingQueue
    /// Потокобезопасное состояние для сетевого слоя (снимок + токены + pairing).
    let state: HostState

    init(queue: OutgoingQueue, state: HostState = HostState()) {
        self.queue = queue
        self.state = state
    }

    /// Пересобирает снимок раздачи из текущей очереди и публикует его в `HostState`.
    ///
    /// Файлы индексируются по `"<albumId>/<fileName>"`; sha256 берётся из уже
    /// посчитанного при постановке в очередь манифеста (повторно не хешируем).
    /// URL файла резолвится в папке-источнике альбома.
    func refreshSnapshot() {
        var files: [String: HostSnapshot.ServedFile] = [:]
        var albums: [ManifestAlbum] = []

        for queued in queue.albums {
            let album = queued.manifestAlbum
            albums.append(album)
            let folder = queued.sourceFolder

            for track in album.tracks {
                let key = HostSnapshot.relativePath(albumId: album.id, fileName: track.fileName)
                files[key] = HostSnapshot.ServedFile(
                    url: folder.appendingPathComponent(track.fileName),
                    sha256: track.sha256,
                    fileSize: track.fileSize
                )
            }
            if let artwork = album.artwork {
                let key = HostSnapshot.relativePath(albumId: album.id, fileName: artwork.fileName)
                files[key] = HostSnapshot.ServedFile(
                    url: folder.appendingPathComponent(artwork.fileName),
                    sha256: artwork.sha256,
                    fileSize: artwork.fileSize
                )
            }
            if let playlist = album.playlist {
                let key = HostSnapshot.relativePath(albumId: album.id, fileName: playlist.fileName)
                files[key] = HostSnapshot.ServedFile(
                    url: folder.appendingPathComponent(playlist.fileName),
                    sha256: playlist.sha256,
                    fileSize: playlist.fileSize
                )
            }
        }

        let snapshot = HostSnapshot(
            manifest: SyncManifest(albums: albums),
            files: files
        )
        state.setSnapshot(snapshot)
    }

    /// Обрабатывает `POST /confirm { albumId }` от телефона: альбом разложен и
    /// сверен — помечаем доставленным и убираем из очереди, затем пересобираем
    /// снимок (сервер перестаёт его раздавать).
    ///
    /// Возвращает true, если такой альбом был в очереди (иначе confirm на пустоту —
    /// всё равно отвечаем 200 на стороне сервера: идемпотентность).
    @discardableResult
    func confirm(albumId: String) -> Bool {
        let existed = queue.albums.contains { $0.id == albumId }
        if let album = queue.albums.first(where: { $0.id == albumId }) {
            album.status = .delivered
        }
        queue.remove(id: albumId)
        refreshSnapshot()
        return existed
    }
}
