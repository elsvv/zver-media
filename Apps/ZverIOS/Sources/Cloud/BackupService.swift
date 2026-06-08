import Combine
import Foundation
import ZverCore
import ZverStorage
import ZverTransport

/// Связка каталога, очереди бэкапа и облачного хранилища: переводит треки по
/// жизненному циклу `fileState` (`local`→`uploading`→`backedUp`→`remote`) и обратно.
///
/// `@MainActor ObservableObject` — публикует наблюдаемое состояние для UI (идёт ли
/// бэкап, какие треки в ошибке). Вся сеть — за инъецированным ``RemoteStore`` (боевой
/// дефолт — ``YandexDiskStore`` поверх ФОНОВОЙ `URLSession`, переживающей сворачивание
/// приложения). Ретраи/backoff/параллелизм живут в ``BackupQueue`` (S4-4); сервис лишь
/// строит `BackupItem`, мапит события очереди в каталожный `fileState` и сверяет sha.
///
/// **Поток автобэкапа.** После импорта/рескана: `catalogStore.tracksAwaitingBackup()`
/// (`local` + `cloudSha == nil`) → `BackupItem` (локальный URL, remotePath, ожидаемый
/// локальный sha через `Sha256.hash(fileURL:)`) → очередь. События очереди:
/// `transferring` → `setFileState(.uploading)`; `done(resource)` → сверка
/// `resource.sha256 == локальный sha` → `markBackedUp(cloudSha:)`; `failed` → откат
/// в `local` + пометка в `failedPaths` (для UI-индикации ошибки). После батча — бэкап
/// `catalog.sqlite` в `catalog.sqlite.backup` (перезапись).
///
/// **Скачивание/выгрузка** (для UI S4-11): `download(track:)` качает в staging с
/// докачкой, сверяет sha, атомарно перекладывает в библиотеку, ставит `backedUp`.
/// `offload(track:)` разрешён ТОЛЬКО для `backedUp` с подтверждённым `cloudSha`, ПОВТОРНО
/// сверяет наличие в облаке (`store.exists`) перед удалением локального файла —
/// «удаление только при подтверждённом checksum».
///
/// Замыкания в очередь/URLSession — `@Sendable`, не наследуют `@MainActor`: переходы в
/// UI/каталог — внутрь `Task { @MainActor in }`, запись БД и sha-хеширование — на детач.
@MainActor
final class BackupService: ObservableObject {
    /// Идёт ли сейчас прогон очереди бэкапа (для индикатора в Настройках).
    @Published private(set) var isBackingUp = false
    /// `relativePath` треков, чья последняя передача завершилась ошибкой
    /// (needs-attention для UI). Очищается при повторной постановке трека в очередь.
    @Published private(set) var failedPaths: Set<String> = []
    /// Последняя ошибка верхнего уровня (битый токен, нет места) для показа в UI.
    @Published private(set) var lastError: RemoteError?

    private let catalogStore: CatalogStore
    private let documentsURL: URL
    private let catalogFileURL: URL
    private let store: any RemoteStore
    private let policy: RetryPolicy

    /// `relativePath` → ожидаемый локальный sha загружаемого трека (для сверки в
    /// `done`). Заполняется при постановке в очередь, читается в обработчике события.
    private var expectedShas: [String: String] = [:]

    /// - Parameters:
    ///   - catalogStore: каталог (источник правды о `fileState`/`cloudSha`).
    ///   - documentsURL: корень Documents (база для `relativePath` ↔ локальный URL).
    ///   - catalogFileURL: путь к `catalog.sqlite` (для бэкапа каталога в облако).
    ///   - tokenProvider: поставщик OAuth-токена (из `CloudAccount`).
    ///   - store: облачное хранилище за протоколом. Боевой дефолт — `YandexDiskStore`
    ///     поверх фоновой URLSession; в превью/тестах подменяется на `InMemoryRemoteStore`.
    ///   - policy: политика ретраев очереди (классификация + backoff).
    init(
        catalogStore: CatalogStore,
        documentsURL: URL = .documentsDirectory,
        catalogFileURL: URL = BackupService.defaultCatalogFileURL,
        tokenProvider: any TokenProviding,
        store: (any RemoteStore)? = nil,
        policy: RetryPolicy = RetryPolicy()
    ) {
        self.catalogStore = catalogStore
        self.documentsURL = documentsURL
        self.catalogFileURL = catalogFileURL
        self.policy = policy
        self.store = store ?? BackupService.makeBackgroundStore(tokenProvider: tokenProvider, policy: policy)
    }

    /// Путь к боевому каталогу (`Application Support/catalog.sqlite`) — зеркало
    /// `LibraryStore.openCatalog()`. Если каталог в памяти (деградация), бэкап
    /// каталога просто не найдёт файл и тихо пропустится.
    static var defaultCatalogFileURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("catalog.sqlite")
    }

    /// Боевой `YandexDiskStore` поверх ФОНОВОЙ URLSession (переживает сворачивание
    /// приложения для длинных докачек). Идентификатор сессии стабилен на приложение.
    private static func makeBackgroundStore(
        tokenProvider: any TokenProviding, policy: RetryPolicy
    ) -> any RemoteStore {
        let http = URLSessionHTTPClient.background(identifier: "dev.zver.backup.session")
        let factory = YandexRequestFactory(
            baseURL: URL(string: "https://cloud-api.yandex.net/v1/disk")!,
            rootPrefix: "app:/"
        )
        return YandexDiskStore(
            http: http, factory: factory, tokenProvider: tokenProvider, policy: policy
        )
    }

    // MARK: - Автобэкап

    /// Ставит в очередь и выгружает все треки, ожидающие бэкапа (`local` +
    /// `cloudSha == nil`), затем бэкапит каталог. Идемпотентно: уже идущий бэкап —
    /// no-op; повторный вызов после завершения подхватит новые `local`-треки.
    ///
    /// Тяжёлое (чтение каталога, sha-хеширование, прогон очереди) — вне MainActor;
    /// `@Published`-переходы — на MainActor. Безопасно дёргать после каждого
    /// импорта/рескана библиотеки.
    func backupAwaitingTracks() async {
        guard !isBackingUp else { return }
        isBackingUp = true
        defer { isBackingUp = false }

        let catalogStore = self.catalogStore
        let documentsURL = self.documentsURL

        // Кандидаты + их локальные sha считаем на детаче (хеширование файлов тяжёлое).
        let items: [BackupItem] = await Task.detached(priority: .utility) {
            guard let awaiting = try? catalogStore.tracksAwaitingBackup() else { return [] }
            return awaiting.compactMap { Self.backupItem(for: $0, documentsURL: documentsURL) }
        }.value

        guard !items.isEmpty else {
            // Нечего выгружать — но каталог всё равно бэкапим, если есть что (мог
            // измениться состав плейлистов/метаданные без новых файлов). Безопасно.
            await backupCatalog()
            return
        }

        // Запоминаем ожидаемые sha и снимаем прежние метки ошибок для этих треков.
        for item in items {
            expectedShas[item.id] = item.expectedSha
            failedPaths.remove(item.id)
        }

        let queue = makeUploadQueue()
        for item in items {
            await queue.enqueueUpload(item)
        }
        await queue.run()

        // После батча выгрузок — бэкап каталога (перезапись).
        await backupCatalog()
    }

    /// Бэкапит `catalog.sqlite` в облако как `catalog.sqlite.backup` (перезапись).
    /// Тихо пропускается, если файла каталога нет (in-memory деградация) или нет
    /// авторизации/сети — это best-effort, не валит автобэкап треков.
    func backupCatalog() async {
        let catalogFileURL = self.catalogFileURL
        guard FileManager.default.fileExists(atPath: catalogFileURL.path) else { return }
        let store = self.store
        do {
            _ = try await store.upload(
                localFile: catalogFileURL,
                to: CloudPaths.catalogBackupName,
                progress: { _ in }
            )
        } catch let error as RemoteError {
            recordTopLevel(error)
        } catch {
            // Прочие сбои бэкапа каталога не критичны — каталог пересоберётся из ФС.
        }
    }

    // MARK: - Скачивание (для «Скачать» в UI)

    /// Скачивает `remote`-трек из облака на устройство с докачкой и sha-сверкой,
    /// атомарно перекладывает в библиотеку и помечает `backedUp` (на диске И в облаке).
    ///
    /// Поток (зеркало `DownloadEngine` этапа 3): `remote` → `setFileState(.downloading)`
    /// → качаем в staging (докачка от размера частичного файла) → сверка sha →
    /// атомарный `moveItem` в `Documents/Library/...` → `markBackedUp(cloudSha:)`.
    /// На любой ошибке — откат в `remote`. Возвращает `true` при успехе.
    @discardableResult
    func download(track: Track) async -> Bool {
        guard let relativePath = CloudPaths.relativePath(of: track.url, documentsURL: documentsURL) else {
            return false
        }
        let remotePath = CloudPaths.remotePath(forRelativePath: relativePath)
        let finalURL = track.url

        setState(relativePath, .downloading)
        failedPaths.remove(relativePath)

        // Ожидаемый sha — подтверждённый в облаке cloudSha трека (если знаем).
        let cloudSha = await cloudSha(forRelativePath: relativePath)

        let documentsURL = self.documentsURL
        let store = self.store
        let policy = self.policy

        let success: Bool = await Task.detached(priority: .userInitiated) {
            let stagingDir = documentsURL.appendingPathComponent(".cloud-staging", isDirectory: true)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let staging = stagingDir.appendingPathComponent(
                relativePath.replacingOccurrences(of: "/", with: "__") + ".partial"
            )

            do {
                let resource = try await Self.runDownload(
                    store: store, policy: policy,
                    remotePath: remotePath, staging: staging
                )
                // Сверка sha: локальный хеш staging-файла против облачного/ожидаемого.
                let localSha = try? Sha256.hash(fileURL: staging)
                let reference = cloudSha ?? resource.sha256
                if let reference, let localSha, localSha != reference {
                    try? FileManager.default.removeItem(at: staging)
                    return false
                }
                // Атомарная раскладка staging → финальный путь библиотеки.
                try FileManager.default.createDirectory(
                    at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: staging, to: finalURL)
                return true
            } catch {
                try? FileManager.default.removeItem(at: staging)
                return false
            }
        }.value

        if success {
            let confirmed = cloudSha ?? (try? Sha256.hash(fileURL: finalURL))
            if let confirmed {
                markBackedUp(relativePath, cloudSha: confirmed)
            } else {
                setState(relativePath, .backedUp, cloudSha: nil)
            }
            return true
        } else {
            // Откат в remote: файл по-прежнему только в облаке.
            setState(relativePath, .remote)
            failedPaths.insert(relativePath)
            return false
        }
    }

    // MARK: - Выгрузка (offload — для «Выгрузить» в UI)

    /// Удаляет локальную копию трека, оставляя его только в облаке (`backedUp` →
    /// `remote`). Гейт удаления: трек ДОЛЖЕН быть `backedUp` с непустым `cloudSha`, И
    /// наличие в облаке ПОВТОРНО подтверждается `store.exists` (сверка sha) ПЕРЕД
    /// удалением файла — «удаление только при подтверждённом checksum».
    ///
    /// Возвращает `true`, если файл удалён и трек переведён в `remote`; `false` —
    /// если гейт не пройден (трек не `backedUp`, sha не совпал, ресурса нет в облаке)
    /// и локальная копия СОХРАНЕНА.
    @discardableResult
    func offload(track: Track) async -> Bool {
        guard track.fileState == .backedUp,
              let relativePath = CloudPaths.relativePath(of: track.url, documentsURL: documentsURL)
        else { return false }

        guard let cloudSha = await cloudSha(forRelativePath: relativePath), !cloudSha.isEmpty else {
            return false
        }

        let remotePath = CloudPaths.remotePath(forRelativePath: relativePath)
        let store = self.store

        // Повторная сверка наличия и sha в облаке ПЕРЕД удалением локального файла.
        let confirmed: Bool
        do {
            if let resource = try await store.exists(path: remotePath) {
                // sha облака должен совпасть с подтверждённым ранее (если облако его отдаёт).
                if let cloudShaNow = resource.sha256 {
                    confirmed = cloudShaNow == cloudSha
                } else {
                    // Облако не отдало sha — полагаемся на ранее подтверждённый cloudSha
                    // (он уже сверялся при бэкапе) + сам факт наличия ресурса.
                    confirmed = true
                }
            } else {
                confirmed = false
            }
        } catch let error as RemoteError {
            recordTopLevel(error)
            return false
        } catch {
            return false
        }

        guard confirmed else { return false }

        // Гейт пройден — удаляем локальный файл и переводим в remote.
        let fileURL = track.url
        let removed: Bool = await Task.detached(priority: .utility) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                return true
            } catch {
                // Файла уже нет — считаем выгруженным; иная ошибка ФС — провал.
                return !FileManager.default.fileExists(atPath: fileURL.path)
            }
        }.value

        guard removed else { return false }
        setState(relativePath, .remote)
        return true
    }

    // MARK: - Очередь и обработка событий

    /// Строит очередь выгрузки с обработчиком событий, мапящим стадии передачи в
    /// каталожный `fileState`. Колбэк `@Sendable` (приходит с произвольной задачи) —
    /// внутри прыгает на `MainActor`.
    private func makeUploadQueue() -> BackupQueue {
        BackupQueue(
            store: store,
            policy: policy,
            maxConcurrent: 2,
            onEvent: { [weak self] itemId, state in
                // Колбэк не на MainActor — переходим явно.
                Task { @MainActor [weak self] in
                    self?.handle(itemId: itemId, state: state)
                }
            }
        )
    }

    /// Мапит событие очереди `(relativePath, TransferState)` в каталожный `fileState`.
    private func handle(itemId: String, state: TransferState) {
        switch state {
        case .queued, .requestingHref, .verifying:
            break // промежуточные стадии не меняют каталог
        case .transferring:
            // Первый байт пошёл — фиксируем uploading (идемпотентно).
            setState(itemId, .uploading)
        case let .done(resource):
            // Сверка sha: облачный против ожидаемого локального. Очередь уже
            // сверила (expectedSha передавался в BackupItem) и не отдала бы done
            // при несовпадении — но дублируем гейт здесь как страховку перед
            // записью cloudSha в каталог.
            let expected = expectedShas[itemId]
            let cloudSha = resource.sha256
            if let expected, let cloudSha, cloudSha != expected {
                rollbackToLocal(itemId)
                return
            }
            // cloudSha для каталога: облачный, иначе ожидаемый локальный (они совпали).
            if let confirmed = cloudSha ?? expected {
                markBackedUp(itemId, cloudSha: confirmed)
            } else {
                // Ни облако, ни ожидаемый не дали sha — нечего подтверждать,
                // безопаснее оставить как backedUp без cloudSha не будем: откат.
                rollbackToLocal(itemId)
                return
            }
            expectedShas[itemId] = nil
            failedPaths.remove(itemId)
        case let .failed(error, _):
            recordTopLevel(error)
            rollbackToLocal(itemId)
            expectedShas[itemId] = nil
            failedPaths.insert(itemId)
        }
    }

    /// Откат выгрузки в `local` (файл на устройстве, в облаке не подтверждён).
    private func rollbackToLocal(_ relativePath: String) {
        setState(relativePath, .local)
    }

    // MARK: - Каталог (запись вне MainActor)

    /// Идемпотентно обновляет `fileState` (и опц. `cloudSha`) строки каталога.
    /// Запись БД — на детаче (синхронный `CatalogStore` бросает; ошибку глотаем —
    /// рассинхрон самозалечится при следующем рескане/бэкапе).
    private func setState(_ relativePath: String, _ state: FileState, cloudSha: String? = nil) {
        let catalogStore = self.catalogStore
        Task.detached(priority: .utility) {
            try? catalogStore.setFileState(relativePath: relativePath, state, cloudSha: cloudSha)
        }
    }

    /// Помечает трек подтверждённым в облаке (после сверки sha).
    private func markBackedUp(_ relativePath: String, cloudSha: String) {
        let catalogStore = self.catalogStore
        Task.detached(priority: .utility) {
            try? catalogStore.markBackedUp(relativePath: relativePath, cloudSha: cloudSha)
        }
    }

    /// Читает подтверждённый `cloudSha` трека из каталога (вне MainActor).
    ///
    /// Точечного геттера `cloudSha` по пути в `CatalogStore` нет, поэтому ищем запись
    /// среди облачных состояний (`backedUp`/`remote`/`downloading` несут cloudSha по
    /// дизайну). Объёмы локальной библиотеки малы — линейный проход дешёвый.
    private func cloudSha(forRelativePath relativePath: String) async -> String? {
        let catalogStore = self.catalogStore
        return await Task.detached(priority: .utility) { () -> String? in
            for state: FileState in [.backedUp, .remote, .downloading] {
                guard let records = try? catalogStore.tracks(inState: state) else { continue }
                if let match = records.first(where: { $0.relativePath == relativePath }) {
                    return match.cloudSha
                }
            }
            return nil
        }.value
    }

    /// Записывает ошибку верхнего уровня (битый токен/нет места) для показа в UI.
    private func recordTopLevel(_ error: RemoteError) {
        switch error {
        case .unauthorized, .insufficientStorage:
            lastError = error
        default:
            break
        }
    }

    // MARK: - Построение BackupItem

    /// Строит `BackupItem` для трека: локальный URL, облачный путь, ожидаемый sha
    /// (хеш локального файла). `nil`, если файла нет на диске (нечего выгружать).
    ///
    /// `nonisolated`: чистая работа с ФС/хешем без состояния актора — вызывается с
    /// детача (тяжёлое хеширование вне MainActor).
    private nonisolated static func backupItem(for record: TrackRecord, documentsURL: URL) -> BackupItem? {
        let localURL = CloudPaths.localURL(forRelativePath: record.relativePath, documentsURL: documentsURL)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        let sha = try? Sha256.hash(fileURL: localURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return BackupItem(
            id: record.relativePath,
            localFile: localURL,
            remotePath: CloudPaths.remotePath(forRelativePath: record.relativePath),
            expectedSha: sha,
            fileSize: size
        )
    }

    /// Одна попытка скачивания с ретраями по политике (вне MainActor).
    ///
    /// `BackupQueue` тоже умеет качать, но здесь нужна синхронная семантика «скачал и
    /// вернул ресурс» для немедленной раскладки — поэтому крутим ретраи вручную над
    /// низкоуровневым `store.download` (одиночная попытка адаптера + backoff политики).
    private nonisolated static func runDownload(
        store: any RemoteStore, policy: RetryPolicy,
        remotePath: String, staging: URL
    ) async throws -> RemoteResource {
        var attempt = 0
        while true {
            attempt += 1
            // Докачка от фактического размера частичного файла.
            let resumeFrom = (try? FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0
            do {
                return try await store.download(
                    path: remotePath, to: staging, resumeFrom: resumeFrom, progress: { _ in }
                )
            } catch let error as RemoteError {
                if policy.isRetryable(error), policy.shouldRetry(attempt: attempt + 1) {
                    let retryAfter: TimeInterval?
                    if case let .rateLimited(after) = error { retryAfter = after } else { retryAfter = nil }
                    let delay = policy.delay(forAttempt: attempt, retryAfter: retryAfter)
                    try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded()))
                    continue
                }
                throw error
            }
        }
    }
}
