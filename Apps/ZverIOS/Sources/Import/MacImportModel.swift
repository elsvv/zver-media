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

    private let browser: ServiceBrowser
    private let keyStore: KeyStore
    /// Фабрика клиента по имени сервиса — инъектируется для тестируемости/превью.
    private let clientFactory: @Sendable (String) -> MacSyncClient
    private var isBrowsing = false

    init(browser: ServiceBrowser = NWServiceBrowser(),
         keyStore: KeyStore = KeychainKeyStore(),
         clientFactory: @escaping @Sendable (String) -> MacSyncClient = { MacSyncClient(serviceName: $0) }) {
        self.browser = browser
        self.keyStore = keyStore
        self.clientFactory = clientFactory
    }

    // MARK: - Обнаружение

    /// Запускает браузинг `_zver._tcp`. Колбэк приходит на сетевой очереди —
    /// возврат в UI через `Task { @MainActor in … }`.
    func startBrowsing() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.start { [weak self] services in
            // @Sendable-колбэк на сетевой очереди: не трогаем self напрямую,
            // прыгаем на MainActor.
            Task { @MainActor [weak self] in
                self?.discoveredMacs = services
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
                phase = .ready(manifest)
            } catch let MacSyncClient.ClientError.httpStatus(code) where code == 401 || code == 403 {
                // Токен больше не принимается — забываем его, просим код заново.
                try? keyStore.delete(forService: service)
                phase = .needsCode
            } catch {
                phase = .failed(Self.message(for: error))
            }
        }
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
        default:
            return "Что-то пошло не так. Повторите попытку."
        }
    }
}
