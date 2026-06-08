import Foundation
import Network

/// Адаптер `WebSocketClient` поверх `NWConnection` + `NWProtocolWebSocket`
/// (роль Mac, этап 5). Зеркало `MacSyncClient` этапа 3, только
/// application-protocol = WebSocket и соединение долгоживущее (не одноразовое).
///
/// Браузер отдаёт только имя Bonjour-сервиса — коннектимся прямо к
/// `NWEndpoint.service(name:type:domain:)`, система резолвит адрес сама (как в
/// `MacSyncClient`). receive-loop декодит входящие `RemoteMessage`; отправка
/// кодит и шлёт текстовым фреймом.
///
/// Concurrency (краш-класс Swift 6): все колбэки `NWConnection` — `@Sendable`,
/// на сетевой очереди, не наследуют `@MainActor`. Состояние соединения и защита
/// одного резюма перехода `ready`/`disconnected`/`failed` — под `NSLock` (по
/// образцу `ContinuationBox` из `MacSyncClient`): `onState(.ready)` шлётся ровно
/// раз, любое завершение → один терминальный `onState`. Тестами НЕ покрывается.
///
/// `@unchecked Sendable` оправдан: всё мутабельное под замком, `connection`
/// пересоздаётся в `connect` на новой сессии.
public final class NWWebSocketClient: WebSocketClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.zver.ws-client")
    private let codec = RemoteCodec()

    private let lock = NSLock()
    private var session: Session?

    public init() {}

    public func connect(to service: DiscoveredService,
                        onMessage: @escaping @Sendable (RemoteMessage) -> Void,
                        onState: @escaping @Sendable (WebSocketConnectionState) -> Void) {
        disconnect()

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let endpoint = NWEndpoint.service(
            name: service.name,
            type: zverServiceType,
            domain: "local.",
            interface: nil
        )
        let connection = NWConnection(to: endpoint, using: parameters)

        let session = Session(
            connection: connection,
            codec: codec,
            onMessage: onMessage,
            onState: onState
        )

        lock.lock()
        self.session = session
        lock.unlock()

        onState(.connecting)
        session.start(on: queue)
    }

    public func send(_ message: RemoteMessage) {
        lock.lock()
        let session = self.session
        lock.unlock()
        session?.send(message)
    }

    public func disconnect() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.close()
    }
}

/// Одна клиентская WebSocket-сессия: receive-loop → `RemoteCodec.decode` →
/// `onMessage`; терминальный переход состояния шлётся ровно один раз.
///
/// `@unchecked Sendable` оправдан: флаги/колбэки под `NSLock`, колбэки
/// `NWConnection` `@Sendable` на сетевой очереди.
private final class Session: @unchecked Sendable {
    private let connection: NWConnection
    private let codec: RemoteCodec
    private let onMessage: @Sendable (RemoteMessage) -> Void
    private let onState: @Sendable (WebSocketConnectionState) -> Void

    private let lock = NSLock()
    /// `ready` уже отправлен — не дублировать при повторных `.ready`.
    private var didReportReady = false
    /// Терминальное состояние (disconnected/failed) уже отправлено — гарантия
    /// одного резюма по образцу `ContinuationBox` из `MacSyncClient`.
    private var didFinish = false

    init(connection: NWConnection,
         codec: RemoteCodec,
         onMessage: @escaping @Sendable (RemoteMessage) -> Void,
         onState: @escaping @Sendable (WebSocketConnectionState) -> Void) {
        self.connection = connection
        self.codec = codec
        self.onMessage = onMessage
        self.onState = onState
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            switch state {
            case .ready:
                self?.reportReady()
                self?.receive()
            case let .failed(error):
                self?.finish(.failed(error))
            case .cancelled:
                self?.finish(.disconnected)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ message: RemoteMessage) {
        guard let data = try? codec.encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data,
                        contentContext: context,
                        isComplete: true,
                        completion: .contentProcessed { @Sendable _ in })
    }

    func close() {
        finish(.disconnected)
    }

    // MARK: - Приём

    private func receive() {
        connection.receiveMessage { @Sendable [weak self] content, context, _, error in
            guard let self else { return }

            if let context, Self.isClose(context) {
                self.finish(.disconnected)
                return
            }
            if let content, !content.isEmpty,
               let message = try? self.codec.decode(content) {
                self.onMessage(message)
            }
            if let error {
                self.finish(.failed(error))
                return
            }
            self.receive()
        }
    }

    // MARK: - Однократные переходы (под замком)

    private func reportReady() {
        lock.lock()
        if didReportReady || didFinish { lock.unlock(); return }
        didReportReady = true
        lock.unlock()
        onState(.ready)
    }

    /// Терминальный переход: шлёт ровно один `disconnected`/`failed` и закрывает
    /// соединение (как `ContinuationBox.resume`).
    private func finish(_ state: WebSocketConnectionState) {
        lock.lock()
        if didFinish { lock.unlock(); return }
        didFinish = true
        lock.unlock()
        connection.cancel()
        onState(state)
    }

    private static func isClose(_ context: NWConnection.ContentContext) -> Bool {
        guard let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata else { return false }
        return metadata.opcode == .close
    }
}
