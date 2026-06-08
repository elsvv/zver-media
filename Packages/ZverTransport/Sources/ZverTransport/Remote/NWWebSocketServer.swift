import Foundation
import Network

/// Адаптер `WebSocketServing` поверх `NWListener` + `NWProtocolWebSocket`
/// (роль iPhone, этап 5). Зеркало `FileServer` этапа 3, только
/// application-protocol = WebSocket и возим `RemoteMessage`, а не HTTP.
///
/// `NWParameters.tcp` + `NWProtocolWebSocket.Options` как application-protocol →
/// слушатель сам ведёт WebSocket-handshake; дальше принимает/шлёт текстовые
/// фреймы. Bonjour-анонс (`svc=remote`) вешается на ЭТОТ ЖЕ слушатель
/// (`listener.service`) — отдельный второй `NWListener` на том же порту дал бы
/// EADDRINUSE (фикс из ревью S3-9).
///
/// Concurrency (краш-класс Swift 6): ВСЕ колбэки `NWListener`/`NWConnection` —
/// `@Sendable`, исполняются на сетевой очереди `queue`, не наследуют `@MainActor`.
/// Словарь клиентов — под `NSLock`. Переход в плеер/UI делает app-слой (S5-4)
/// внутри `Task { @MainActor in … }`. Тестами НЕ покрывается — рантайм-сеть за
/// протоколом; сетевую часть проверяет владелец на железе.
///
/// `@unchecked Sendable` оправдан: мутабельный `listener` живёт на `queue`,
/// словарь соединений — под замком.
public final class NWWebSocketServer: WebSocketServing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.zver.ws-server")
    private let codec = RemoteCodec()

    private let lock = NSLock()
    private var listener: NWListener?
    /// Активные соединения по `RemoteClientID` (для адресной отправки/broadcast).
    private var clients: [RemoteClientID: ClientConnection] = [:]
    /// Монотонный счётчик для выдачи `RemoteClientID`.
    private var nextClientID: UInt64 = 1

    public init() {}

    // MARK: - Жизненный цикл

    public func start(port: UInt16?,
                      name: String?,
                      txt: [String: String],
                      onClient: @escaping @Sendable (RemoteClientHandle) -> Void,
                      onReady: @escaping @Sendable (UInt16) -> Void,
                      onFailure: @escaping @Sendable (Error) -> Void) {
        stop()

        // WebSocket поверх TCP: options как application-protocol слушателя.
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        // Сервер не шлёт авто-pong сам — но автоответ на ping держит соединение
        // живым без участия app-слоя.
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let nwPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            onFailure(error)
            return
        }

        // Bonjour-анонс на этом же слушателе (без второго bind → без EADDRINUSE).
        if let name {
            listener.service = NWListener.Service(
                name: name,
                type: zverServiceType,
                txtRecord: NWTXTRecord(txt)
            )
        }

        listener.stateUpdateHandler = { @Sendable state in
            switch state {
            case .ready:
                if let rawPort = listener.port?.rawValue {
                    onReady(rawPort)
                }
            case let .failed(error):
                onFailure(error)
            default:
                break
            }
        }

        listener.newConnectionHandler = { @Sendable [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = self.makeClientID()
            let client = ClientConnection(
                id: id,
                connection: connection,
                queue: self.queue,
                codec: self.codec,
                onClose: { [weak self] in self?.removeClient(id) }
            )
            self.addClient(id: id, client: client)
            // Сообщаем app-слою о новом клиенте ДО старта приёма, чтобы он успел
            // подписать onMessage/onClose (handshake идёт асинхронно).
            onClient(client)
            client.start()
        }

        lock.lock()
        self.listener = listener
        lock.unlock()
        listener.start(queue: queue)
    }

    public func send(_ message: RemoteMessage, to client: RemoteClientID) {
        lock.lock()
        let connection = clients[client]
        lock.unlock()
        connection?.send(message)
    }

    public func broadcast(_ message: RemoteMessage) {
        lock.lock()
        let all = Array(clients.values)
        lock.unlock()
        for connection in all {
            connection.send(message)
        }
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        let all = Array(clients.values)
        clients.removeAll()
        lock.unlock()

        listener?.cancel()
        for connection in all {
            connection.close()
        }
    }

    // MARK: - Учёт клиентов (под замком)

    private func makeClientID() -> RemoteClientID {
        lock.lock(); defer { lock.unlock() }
        let id = RemoteClientID(rawValue: nextClientID)
        nextClientID += 1
        return id
    }

    private func addClient(id: RemoteClientID, client: ClientConnection) {
        lock.lock()
        clients[id] = client
        lock.unlock()
    }

    private func removeClient(_ id: RemoteClientID) {
        lock.lock()
        clients[id] = nil
        lock.unlock()
    }
}

/// Одно клиентское WebSocket-соединение на стороне сервера: receive-loop →
/// `RemoteCodec.decode` → `onMessage`, отправка → `RemoteCodec.encode` +
/// `NWProtocolWebSocket.Metadata(opcode: .text)`.
///
/// `@unchecked Sendable` оправдан: подписки/флаг закрытия — под `NSLock`,
/// колбэки `NWConnection` `@Sendable` на сетевой очереди.
private final class ClientConnection: RemoteClientHandle, @unchecked Sendable {
    let id: RemoteClientID

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let codec: RemoteCodec
    /// Дёргается, когда соединение закрылось (снять из словаря сервера).
    private let onServerClose: @Sendable () -> Void

    private let lock = NSLock()
    private var messageHandler: (@Sendable (RemoteMessage) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var closed = false

    init(id: RemoteClientID,
         connection: NWConnection,
         queue: DispatchQueue,
         codec: RemoteCodec,
         onClose: @escaping @Sendable () -> Void) {
        self.id = id
        self.connection = connection
        self.queue = queue
        self.codec = codec
        self.onServerClose = onClose
    }

    func onMessage(_ handler: @escaping @Sendable (RemoteMessage) -> Void) {
        lock.lock()
        messageHandler = handler
        lock.unlock()
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        closeHandler = handler
        lock.unlock()
    }

    func start() {
        connection.stateUpdateHandler = { @Sendable [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.handleClosed()
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
        handleClosed()
    }

    // MARK: - Приём

    /// Рекурсивно принимает один WebSocket-message за раз. `receiveMessage`
    /// агрегирует фрагменты в целый фрейм, поэтому отдельная сборка не нужна.
    private func receive() {
        connection.receiveMessage { @Sendable [weak self] content, context, _, error in
            guard let self else { return }

            if let context, Self.isClose(context) {
                self.handleClosed()
                return
            }
            // Текстовый фрейм с данными → декод; неизвестный/битый кадр НЕ роняет
            // соединение (forward-compat кодека) — просто пропускаем.
            if let content, !content.isEmpty,
               let message = try? self.codec.decode(content) {
                self.dispatch(message)
            }
            if error != nil {
                self.handleClosed()
                return
            }
            self.receive()
        }
    }

    private func dispatch(_ message: RemoteMessage) {
        lock.lock()
        let handler = messageHandler
        lock.unlock()
        handler?(message)
    }

    /// Закрывает соединение и зовёт `onClose`/серверный сброс ровно один раз.
    private func handleClosed() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let handler = closeHandler
        lock.unlock()

        connection.cancel()
        handler?()
        onServerClose()
    }

    /// WebSocket close-фрейм в контексте сообщения.
    private static func isClose(_ context: NWConnection.ContentContext) -> Bool {
        guard let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata else { return false }
        return metadata.opcode == .close
    }
}
