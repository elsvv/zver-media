import Foundation

/// Идентификатор клиентского WebSocket-соединения на стороне сервера.
///
/// Сервер раздаёт по одному `ClientID` на каждое принятое соединение, чтобы
/// app-слой (S5-4) мог адресно слать `RemoteMessage` конкретному Маку
/// (`send(_:to:)`) и держать на нём состояние авторизации. `Hashable`/`Sendable`
/// — ключ в словарях и безопасная передача через `@Sendable`-колбэки сети.
public struct RemoteClientID: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// WebSocket-СЕРВЕР протокола пульта (роль iPhone).
///
/// Рантайм-сетевой объект спрятан за протоколом (лессон прошлых этапов:
/// `NWListener`/`NWConnection` — за интерфейсом, юнит-тестим только чистую
/// логику кодека/дифа). Адаптер лишь возит `RemoteMessage` текстовыми фреймами;
/// авторизация (`hello`/`pair`) — НЕ здесь, а в app-слое (S5-4).
///
/// Все колбэки приходят на сетевой очереди, не наследуют `@MainActor`: `onClient`
/// и поток входящих сообщений помечены `@Sendable`; переход в плеер/UI делает
/// вызывающая `@MainActor`-модель через `Task { @MainActor in … }`.
public protocol WebSocketServing: Sendable {
    /// Запускает слушатель и Bonjour-анонс `_zver._tcp` с TXT (`svc=remote`).
    ///
    /// - Parameters:
    ///   - port: фиксированный порт или `nil` — система выберет свободный.
    ///   - name: имя Bonjour-сервиса (имя iPhone). `nil` — слушать без анонса
    ///     (превью/сборка).
    ///   - txt: TXT-запись анонса (`name`, `v`, `svc=remote`).
    ///   - onClient: вызывается на каждое новое соединение; отдаёт хэндл клиента
    ///     (для адресной отправки/закрытия) и поток входящих `RemoteMessage`.
    ///   - onReady: фактический порт после старта слушателя.
    ///   - onFailure: ошибка слушателя.
    func start(port: UInt16?,
               name: String?,
               txt: [String: String],
               onClient: @escaping @Sendable (RemoteClientHandle) -> Void,
               onReady: @escaping @Sendable (UInt16) -> Void,
               onFailure: @escaping @Sendable (Error) -> Void)

    /// Шлёт сообщение конкретному клиенту (текстовый фрейм).
    func send(_ message: RemoteMessage, to client: RemoteClientID)

    /// Шлёт сообщение всем подключённым клиентам (пуш состояния/библиотеки).
    func broadcast(_ message: RemoteMessage)

    /// Останавливает слушатель и закрывает все соединения.
    func stop()
}

/// Хэндл одного клиентского соединения, выдаваемый `onClient`.
///
/// Несёт `id` для адресной работы и колбэки жизненного цикла, которые app-слой
/// (S5-4) подписывает: `onMessage` — входящий `RemoteMessage` (после декода
/// `RemoteCodec`), `onClose` — соединение закрылось. Колбэки `@Sendable`
/// (вызов на сетевой очереди). `@unchecked Sendable` оправдан: колбэки под
/// замком в реализации (`NWWebSocketServer`).
public protocol RemoteClientHandle: AnyObject, Sendable {
    /// Идентификатор этого соединения (тот же, что в `send(_:to:)`).
    var id: RemoteClientID { get }

    /// Подписка на входящие сообщения этого клиента. Зовётся на сетевой очереди.
    func onMessage(_ handler: @escaping @Sendable (RemoteMessage) -> Void)

    /// Подписка на закрытие соединения. Зовётся один раз на сетевой очереди.
    func onClose(_ handler: @escaping @Sendable () -> Void)

    /// Закрывает это соединение (например, провал авторизации).
    func close()
}
