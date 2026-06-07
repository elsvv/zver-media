import Foundation
import ZverTransport

/// `@MainActor`-контроллер окна сопряжения на хосте (Маке).
///
/// Открывает окно с 6-значным кодом (`Pairing.generateCode`), сообщает код
/// `HostState` (которое сверяет присланный телефоном код на сетевой очереди и
/// выпускает токен), и зеркалит выпущенные токены в системный Keychain
/// (`KeychainKeyStore`) под сервисом-именем Мака — чтобы сессия переживала
/// перезапуск приложения.
///
/// Сам сетевой обмен (`POST /pair`) обслуживает `FileServer` через `HostState`;
/// здесь — только пользовательское состояние (показать/скрыть код, статус).
@MainActor
final class PairingHostController: ObservableObject {
    /// Текущий показываемый 6-значный код, если окно pairing открыто; иначе nil.
    @Published private(set) var code: String?
    /// Сопряжение состоялось (телефон прислал верный код) — для UI-индикации.
    @Published private(set) var didPair = false

    /// Раздаваемое состояние: сюда кладём код и отсюда забираем выпущенный токен.
    private let state: HostState
    /// Хранилище токенов сессии (продакшен — Keychain). Тестами не покрываем
    /// (Keychain недоступен без подписи), но тип обязан компилироваться.
    private let keyStore: KeyStore
    /// Имя сервиса для разнесения токенов в Keychain (имя/host Мака).
    private let serviceName: String

    init(state: HostState,
         keyStore: KeyStore = KeychainKeyStore(),
         serviceName: String = PairingHostController.defaultServiceName) {
        self.state = state
        self.keyStore = keyStore
        self.serviceName = serviceName
    }

    /// Имя Мака для Bonjour/Keychain-сервиса (host name, фоллбэк — «Zver Mac»).
    static var defaultServiceName: String {
        let host = Host.current().localizedName
        if let host, !host.isEmpty { return host }
        return "Zver Mac"
    }

    /// Открывает окно сопряжения: генерирует свежий код и сообщает его `HostState`.
    /// Повторный вызов выдаёт новый код (старый перестаёт приниматься).
    func open() {
        didPair = false
        let newCode = Pairing.generateCode()
        code = newCode
        state.openPairing(code: newCode)
    }

    /// Закрывает окно сопряжения (код больше не принимается).
    func close() {
        code = nil
        state.closePairing()
    }

    /// Опрашивает `HostState`: если сопряжение состоялось и появился новый токен —
    /// зеркалит его в Keychain и помечает `didPair`. Вызывается из UI после
    /// успешного `POST /pair` (например, по таймеру/событию обновления снимка).
    ///
    /// Возвращает true, если в этот момент токен был зафиксирован.
    @discardableResult
    func persistIssuedTokenIfNeeded(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        try? keyStore.save(token: token, forService: serviceName)
        didPair = true
        code = nil
        return true
    }
}
