import Combine
import Foundation
import ZverTransport

/// Модель экрана «Импорт с Мака»: обнаружение Маков, сопряжение (pairing) и
/// загрузка манифеста для предпросмотра очереди Мака.
///
/// `@MainActor` — вся публикуемая модель читается из SwiftUI. Браузер
/// (`NWServiceBrowser`) живёт, пока модель активна (`startBrowsing` /
/// `stopBrowsing`); его `@Sendable`-колбэк прыгает на MainActor через
/// `Task { @MainActor in … }` (краш-класс Swift 6: не наследовать
/// `@MainActor`-изоляцию в фоновые сетевые колбэки).
///
/// Скоуп S3-10: только discovery + pairing + загрузка/предпросмотр манифеста.
/// Сам докачиваемый трансфер файлов — S3-11.
@MainActor
final class MacImportModel: ObservableObject {
    /// Фаза сопряжения с выбранным Маком.
    enum PairingPhase: Equatable {
        /// Мак ещё не выбран — показываем список.
        case idle
        /// Ожидаем ввод 6-значного кода (токена для этого Мака ещё нет).
        case needsCode
        /// Идёт обмен (POST /pair или GET /manifest).
        case connecting
        /// Сопряжение прошло, манифест загружен — показываем предпросмотр.
        case ready(SyncManifest)
        /// Ошибка с сообщением для пользователя.
        case failed(String)
    }

    /// Найденные в сети Маки (отсортированы по имени реестром браузера).
    @Published private(set) var discoveredMacs: [DiscoveredService] = []
    /// Выбранный для импорта Мак (nil — никто не выбран).
    @Published private(set) var selectedMac: DiscoveredService?
    /// Текущая фаза сопряжения/предпросмотра.
    @Published private(set) var phase: PairingPhase = .idle
    /// Активный координатор импорта (создаётся при старте загрузки очереди).
    /// Пока nil — показываем предпросмотр; не-nil — экран прогресса импорта.
    @Published private(set) var importCoordinator: ImportCoordinator?

    private let browser: ServiceBrowser
    private let keyStore: KeyStore
    /// Фабрика клиента по имени сервиса — инъектируется для тестируемости/превью.
    private let clientFactory: @Sendable (String) -> MacSyncClient
    /// Фабрика загрузчика файлов по имени сервиса (рантайм-адаптер `NWConnection`).
    private let downloaderFactory: @Sendable (String) -> RangeDownloading
    /// Корень библиотеки на телефоне (`Documents/Library`) — куда раскладываем альбомы.
    private let libraryRoot: URL
    /// Папка частичных загрузок (вне скана библиотеки).
    private let stagingRoot: URL
    /// Рескан каталога после раскладки альбома (обёртка над `LibraryStore.refresh`).
    private let rescan: @MainActor () async -> Void
    private var isBrowsing = false
    /// Токен текущей сессии (тот, которым успешно загрузился манифест). Держим в
    /// памяти, чтобы импорт работал, даже если запись токена в Keychain не удалась
    /// (иначе `startImport` перечитывал бы Keychain и тихо ничего не делал).
    private var activeToken: String?

    init(browser: ServiceBrowser = NWServiceBrowser(),
         keyStore: KeyStore = KeychainKeyStore(),
         clientFactory: @escaping @Sendable (String) -> MacSyncClient = { MacSyncClient(serviceName: $0) },
         downloaderFactory: @escaping @Sendable (String) -> RangeDownloading = { NWFileDownloader(serviceName: $0) },
         libraryRoot: URL = URL.documentsDirectory.appendingPathComponent("Library", isDirectory: true),
         stagingRoot: URL = URL.cachesDirectory.appendingPathComponent("ZverImport", isDirectory: true),
         rescan: @escaping @MainActor () async -> Void = {}) {
        self.browser = browser
        self.keyStore = keyStore
        self.clientFactory = clientFactory
        self.downloaderFactory = downloaderFactory
        self.libraryRoot = libraryRoot
        self.stagingRoot = stagingRoot
        self.rescan = rescan
    }

    // MARK: - Обнаружение

    /// Запускает браузинг `_zver._tcp`. Колбэк приходит на сетевой очереди —
    /// возврат в UI через `Task { @MainActor in … }`.
    func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.start { [weak self] services in
            // @Sendable-колбэк на сетевой очереди: не трогаем self напрямую,
            // прыгаем на MainActor. Фильтруем по роли: на общем типе `_zver._tcp`
            // живут и синк-сервер Мака (svc отсутствует → sync), и пульт-сервер
            // iPhone (svc=remote). В список «Маков» берём только sync — иначе тап по
            // пульт-сервису слал бы HTTP /pair в WebSocket-сервер (таймаут/мусор).
            let macs = services.filter { $0.role == ServiceTXT.sync }
            Task { @MainActor [weak self] in
                self?.discoveredMacs = macs
            }
        }
    }

    /// Останавливает браузинг (при закрытии экрана).
    func stopBrowsing() {
        guard isBrowsing else { return }
        isBrowsing = false
        browser.stop()
    }

    // MARK: - Выбор Мака и сопряжение

    /// Имя сервиса как ключ хранилища токенов (один Мак — один токен).
    private func serviceKey(for mac: DiscoveredService) -> String { mac.name }

    /// Пользователь выбрал Мак. Если токен уже сохранён — pairing пропускается,
    /// сразу грузим манифест; иначе переходим к вводу кода.
    func select(_ mac: DiscoveredService) {
        selectedMac = mac
        if let token = keyStore.token(forService: serviceKey(for: mac)) {
            phase = .connecting
            loadManifest(for: mac, token: token)
        } else {
            phase = .needsCode
        }
    }

    /// Сбрасывает выбор и возвращается к списку Маков.
    func deselect() {
        selectedMac = nil
        activeToken = nil
        phase = .idle
    }

    /// Отправляет введённый код на выбранный Мак, сохраняет полученный токен и
    /// сразу грузит манифест. Пустой/нецифровой код — мягкая ошибка без сети.
    func submit(code rawCode: String) {
        guard let mac = selectedMac else { return }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == Pairing.codeLength, code.allSatisfy(\.isNumber) else {
            phase = .failed("Код должен состоять из \(Pairing.codeLength) цифр.")
            return
        }

        phase = .connecting
        let client = clientFactory(mac.name)
        let service = serviceKey(for: mac)
        let keyStore = self.keyStore

        Task { @MainActor in
            do {
                let response = try await client.pair(code: code)
                try? keyStore.save(token: response.token, forService: service)
                loadManifest(for: mac, token: response.token)
            } catch {
                phase = .failed(Self.message(for: error))
            }
        }
    }

    /// Если pairing уже был, но пользователь хочет ввести код заново
    /// (например, токен Мака протух) — сбрасываем сохранённый токен.
    func resetPairing() {
        guard let mac = selectedMac else { return }
        activeToken = nil
        try? keyStore.delete(forService: serviceKey(for: mac))
        phase = .needsCode
    }

    /// Грузит манифест с авторизацией токеном и переводит фазу в `.ready`.
    /// При 401/403 (токен невалиден) — сбрасываем его и просим код заново.
    private func loadManifest(for mac: DiscoveredService, token: String) {
        let client = clientFactory(mac.name)
        let service = serviceKey(for: mac)
        let keyStore = self.keyStore

        Task { @MainActor in
            do {
                let manifest = try await client.fetchManifest(token: token)
                activeToken = token
                phase = .ready(manifest)
            } catch let MacSyncClient.ClientError.httpStatus(code) where code == 401 || code == 403 {
                // Токен больше не принимается — забываем его, просим код заново.
                activeToken = nil
                try? keyStore.delete(forService: service)
                phase = .needsCode
            } catch {
                phase = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: - Импорт очереди

    /// Запускает докачиваемую загрузку очереди Мака: строит координатор и
    /// стартует его. Доступно только из фазы `.ready(manifest)` с валидным токеном
    /// для выбранного Мака. Повторный вызов при активном координаторе — no-op.
    func startImport() {
        guard importCoordinator == nil,
              let mac = selectedMac,
              case let .ready(manifest) = phase,
              let token = activeToken
        else { return }

        let serviceName = mac.name
        let downloader = downloaderFactory(serviceName)
        let engine = DownloadEngine(
            libraryRoot: libraryRoot,
            stagingRoot: stagingRoot,
            downloader: downloader,
            token: token
        )

        // Клиент для confirm — отдельный короткоживущий, как и для pair/manifest.
        let confirmClientFactory = clientFactory
        let confirm: @Sendable (String) async throws -> Void = { albumId in
            try await confirmClientFactory(serviceName).confirm(albumId: albumId, token: token)
        }

        // Локальные sha считаем вне главного потока (хеширование лежащих файлов).
        let localShas: @Sendable () async -> [String: String] = {
            await Task.detached(priority: .userInitiated) {
                ImportCoordinator.computeLocalShas(manifest: manifest, engine: engine)
            }.value
        }

        let rescan = self.rescan
        let coordinator = ImportCoordinator(
            manifest: manifest,
            engine: engine,
            confirm: confirm,
            rescan: rescan,
            localShas: localShas
        )
        importCoordinator = coordinator

        Task { @MainActor in
            await coordinator.start()
        }
    }

    /// Закрывает экран прогресса импорта и возвращается к предпросмотру очереди.
    func dismissImport() {
        importCoordinator = nil
    }

    // MARK: - Сообщения об ошибках

    /// Человекочитаемое RU-сообщение по типу сетевой ошибки.
    private static func message(for error: Error) -> String {
        switch error {
        case MacSyncClient.ClientError.timeout:
            return "Мак не ответил вовремя. Проверьте, что окно импорта на Маке открыто."
        case MacSyncClient.ClientError.httpStatus(401), MacSyncClient.ClientError.httpStatus(403):
            return "Неверный код. Попробуйте ещё раз."
        case let MacSyncClient.ClientError.httpStatus(code):
            return "Мак вернул ошибку (\(code))."
        case MacSyncClient.ClientError.connectionFailed:
            return "Не удалось подключиться к Маку. Проверьте, что устройства в одной сети."
        case MacSyncClient.ClientError.decodingFailed,
             MacSyncClient.ClientError.malformedResponse:
            return "Не удалось разобрать ответ Мака."
        case MacSyncClient.ClientError.fileWriteFailed:
            return "Не удалось сохранить файл — возможно, на устройстве закончилось место."
        default:
            return "Что-то пошло не так. Повторите попытку."
        }
    }
}
