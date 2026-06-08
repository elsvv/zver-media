import Foundation

/// WebSocket-КЛИЕНТ протокола пульта (роль Mac).
///
/// Зеркало `WebSocketServing`: коннектится к Bonjour-endpoint обнаруженного
/// сервиса iPhone (`DiscoveredService`), возит `RemoteMessage` текстовыми
/// фреймами. Рантайм-сетевой объект (`NWConnection`) спрятан за протоколом —
/// тестами не покрывается (лессон прошлых этапов).
///
/// Все колбэки приходят на сетевой очереди, не наследуют `@MainActor`:
/// `onMessage`/`onState` помечены `@Sendable`; переход в UI/координатор делает
/// вызывающая `@MainActor`-модель (S5-7) через `Task { @MainActor in … }`.
public protocol WebSocketClient: Sendable {
    /// Подключается к обнаруженному сервису пульта iPhone.
    ///
    /// - Parameters:
    ///   - service: обнаруженный `_zver._tcp svc=remote` сервис (по имени
    ///     резолвится Bonjour-endpoint — host/port не нужны заранее, как в
    ///     `MacSyncClient`).
    ///   - onMessage: каждый входящий `RemoteMessage` (после декода). Зовётся на
    ///     сетевой очереди.
    ///   - onState: смена состояния соединения (для статуса/деградации в UI).
    func connect(to service: DiscoveredService,
                 onMessage: @escaping @Sendable (RemoteMessage) -> Void,
                 onState: @escaping @Sendable (WebSocketConnectionState) -> Void)

    /// Шлёт сообщение серверу (текстовый фрейм).
    func send(_ message: RemoteMessage)

    /// Закрывает соединение.
    func disconnect()
}

/// Состояние клиентского WebSocket-соединения для UI/деградации (S5-7).
///
/// `failed` несёт причину для диагностики; `Sendable` (передаётся через
/// `@Sendable`-колбэк `onState`). Equatable облегчает сравнение в модели
/// (через строковое описание ошибки — `Error` сам не Equatable).
public enum WebSocketConnectionState: Sendable {
    /// Соединение устанавливается.
    case connecting
    /// Соединение готово — handshake WebSocket завершён, можно слать `hello`.
    case ready
    /// Соединение закрылось штатно (`disconnect`/EOF) — «iPhone не в сети».
    case disconnected
    /// Соединение оборвалось с ошибкой.
    case failed(Error)
}
