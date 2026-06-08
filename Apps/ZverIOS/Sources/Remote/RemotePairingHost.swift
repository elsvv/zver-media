import Foundation
import ZverTransport

/// `@MainActor`-хост сопряжения пульта на стороне iPhone (роли этапа 3 перевёрнуты:
/// здесь iPhone — ХОСТ pairing, Mac — клиент).
///
/// Открывает окно сопряжения с 6-значным кодом (`Pairing.generateCode`), сверяет
/// присланный Маком код (`Pairing.verify`, константное время) и при совпадении
/// выпускает одноразовый токен (`Pairing.generateToken`), зеркаля его в системный
/// Keychain (`KeychainKeyStore(account: "zver-remote-token")`, сервис
/// `zver-remote`) — чтобы доверие пережило перезапуск приложения. При следующем
/// подключении Mac шлёт `hello{token}`, который сверяется с этим же выпущенным
/// токеном (`verify(token:)`).
///
/// Чистая сверка/выпуск без сети; сетевой обмен (`pair`/`hello`) обслуживает
/// `RemoteControlService`. Keychain тестами не покрывается (недоступен без
/// подписи), но тип обязан компилироваться на iOS.
@MainActor
final class RemotePairingHost: ObservableObject {
    /// Сервис-ключ Keychain для токена доверенного Мака (один Mac в MVP).
    static let keychainService = "zver-remote"
    /// Аккаунт-метка записи токена пульта (разводит его с синк-токеном этапа 3).
    static let keychainAccount = "zver-remote-token"

    /// Показываемый сейчас 6-значный код, если окно сопряжения открыто; иначе nil.
    @Published private(set) var pairingCode: String?
    /// Состоялось ли сопряжение в текущей сессии (для индикации в UI).
    @Published private(set) var didPair = false

    /// Хранилище токена доверенного Мака (продакшен — Keychain).
    private let keyStore: KeyStore
    /// Сервис-ключ для записи токена в `keyStore`.
    private let service: String

    init(keyStore: KeyStore = KeychainKeyStore(account: RemotePairingHost.keychainAccount),
         service: String = RemotePairingHost.keychainService) {
        self.keyStore = keyStore
        self.service = service
    }

    // MARK: - Окно сопряжения (UI)

    /// Открывает окно сопряжения: генерирует свежий код. Повторный вызов выдаёт
    /// новый код — старый перестаёт приниматься (`verify` сверяет с текущим).
    func openPairing() {
        didPair = false
        pairingCode = Pairing.generateCode()
    }

    /// Закрывает окно сопряжения: код больше не показывается и не принимается.
    func closePairing() {
        pairingCode = nil
    }

    // MARK: - Сверка/выпуск (вызывается из RemoteControlService)

    /// Сверяет присланный Маком код с текущим показываемым (если окно открыто) и
    /// при совпадении выпускает токен, сохраняя его в Keychain. Возвращает токен
    /// при успехе, nil — если окно закрыто или код неверен.
    ///
    /// Сравнение — `Pairing.verify` (константное время). После успеха окно
    /// закрывается (одноразовый код), `didPair = true`.
    func verifyPairing(code: String) -> String? {
        guard let expected = pairingCode,
              Pairing.verify(code: code, expected: expected) else {
            return nil
        }
        let token = Pairing.generateToken()
        try? keyStore.save(token: token, forService: service)
        pairingCode = nil
        didPair = true
        return token
    }

    /// Текущий выпущенный токен доверенного Мака, если он есть в Keychain.
    var issuedToken: String? {
        keyStore.token(forService: service)
    }

    /// Сверяет `hello{token}` с выпущенным токеном (константное время). false —
    /// токена нет (не сопрягались) или он не совпал.
    func verify(token: String) -> Bool {
        guard let issued = issuedToken else { return false }
        return Pairing.verify(code: token, expected: issued)
    }

    /// Снимает доверие: удаляет токен из Keychain (Mac придётся сопрягать заново).
    func revokeTrust() {
        try? keyStore.delete(forService: service)
        didPair = false
    }
}
