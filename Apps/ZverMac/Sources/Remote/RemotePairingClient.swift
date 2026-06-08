import Foundation
import ZverTransport

/// Клиент сопряжения пульта на стороне Мака (роль перевёрнута относительно
/// этапа 3: там Mac был ХОСТОМ pairing, здесь — КЛИЕНТ).
///
/// Сопряжение этапа 5 идёт ПОВЕРХ WebSocket (а не отдельным `POST /pair`, как в
/// синке): координатор отправляет `RemotePayload.pair(code:)` и ждёт ответ
/// `paired(token:)`. Этот тип не держит сети — он лишь:
///   • строит `RemoteMessage` для отправки кода (`pairMessage(code:)`),
///   • при приёме `paired(token:)` зеркалит токен в системный Keychain под
///     сервисом-именем iPhone (`KeychainKeyStore(account:"zver-remote-token")`),
///   • отдаёт сохранённый токен для последующего `hello(token:)`.
///
/// Сервис в Keychain — имя iPhone (разнесение токенов по устройствам); аккаунт
/// фиксирован `zver-remote-token` (зеркало `KeychainKeyStore` синка, где аккаунт
/// фиксирован, а сервис различает Маки). `KeychainKeyStore` тестами не покрыт
/// (Keychain недоступен без подписи) — `InMemoryKeyStore` подставляется в превью/
/// сборочных тестах. Тип `Sendable`: хранилище — `KeyStore` (Sendable).
struct RemotePairingClient: Sendable {
    /// Фиксированный аккаунт записи в Keychain для токенов пульта (сервис —
    /// имя конкретного iPhone). Согласован со спецификацией S5-7.
    static let keychainAccount = "zver-remote-token"

    /// Хранилище токенов сессии (продакшен — Keychain, тесты — in-memory).
    private let keyStore: KeyStore

    init(keyStore: KeyStore = KeychainKeyStore(account: RemotePairingClient.keychainAccount)) {
        self.keyStore = keyStore
    }

    // MARK: - Построение исходящих сообщений

    /// Сообщение `pair{code}` — первый кадр при первом сопряжении с iPhone
    /// (код показан на экране iPhone). Ответ — `paired{token}`.
    func pairMessage(code: String) -> RemoteMessage {
        RemoteMessage(payload: .pair(code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Сообщение `hello{token}` — первый кадр при наличии сохранённого токена
    /// (повторное подключение к уже сопряжённому iPhone). Ответ — `helloAck`.
    func helloMessage(token: String) -> RemoteMessage {
        RemoteMessage(payload: .hello(token: token))
    }

    // MARK: - Токены в Keychain (разнесены по имени iPhone)

    /// Сохранённый токен для данного iPhone, либо nil — тогда нужно сопряжение.
    func token(forDevice deviceName: String) -> String? {
        keyStore.token(forService: deviceName)
    }

    /// Зеркалит выпущенный iPhone токен в Keychain под сервисом-именем iPhone.
    /// Пустой токен игнорируется. Возвращает true, если токен зафиксирован.
    @discardableResult
    func persistToken(_ token: String, forDevice deviceName: String) -> Bool {
        guard !token.isEmpty, !deviceName.isEmpty else { return false }
        try? keyStore.save(token: token, forService: deviceName)
        return true
    }

    /// Забывает токен данного iPhone (например, iPhone отозвал доступ → `helloAck{ok:false}`),
    /// чтобы следующий цикл начался с сопряжения по коду.
    func forgetToken(forDevice deviceName: String) {
        try? keyStore.delete(forService: deviceName)
    }
}
