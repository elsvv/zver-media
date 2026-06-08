import Combine
import Foundation
import UIKit
import ZverCore
import ZverTransport

/// `@MainActor`-сервис «Пульт с Мака» на стороне iPhone (роль СЕРВЕРА).
///
/// Поднимает `NWWebSocketServer` и анонсит `_zver._tcp` TXT `{name, v:"1",
/// svc:"remote"}`. На каждое соединение ждёт авторизацию ПОВЕРХ WebSocket:
/// `hello{token}` (сверка с выпущенным токеном) ИЛИ `pair{code}` (сверка кода →
/// `paired{token}`). До авторизации команды игнорируются. После авторизации шлёт
/// `library` + текущий `state`, принимает команды транспорта → `PlayerEngine` и
/// запросы библиотеки/`playAlbum` → через `RemoteLibraryBuilder` + `LibraryStore`.
///
/// Наблюдает `PlayerEngine.$state/$queue/$currentTime` (Combine) → строит
/// `RemotePlayerState` → `RemoteStateDiff.shouldEmit` → `broadcast(state)`. На
/// изменение `LibraryStore.$albums` рассылает свежую `library`.
///
/// Concurrency (краш-класс Swift 6): колбэки сети (`onClient`/`onMessage`/
/// `onClose`) приходят `@Sendable` на сетевой очереди и НЕ наследуют `@MainActor`;
/// весь переход в плеер/библиотеку/состояние сервиса — через `Task { @MainActor
/// in … }`. `NowPlayingService`/`MPRemoteCommandCenter` НЕ трогаем: системные и
/// пультовые команды оба идут в `PlayerEngine` и сосуществуют.
@MainActor
final class RemoteControlService: ObservableObject {
    /// Минимальный значимый сдвиг позиции (с) для пуша `state` (троттлинг).
    private static let positionThreshold: Double = 0.5

    /// Включён ли пульт пользователем (тумблер в Настройках). Сервер живёт, пока
    /// `isEnabled == true` И жив background audio (играет или режим «всегда на
    /// связи» — этим заведует S5-5; здесь — только сервер).
    @Published private(set) var isEnabled = false
    /// Число авторизованных подключений (для статуса «Mac подключён» в UI).
    @Published private(set) var connectedClients = 0

    /// Хост сопряжения: код/токен/Keychain. Доступен UI напрямую (показ кода).
    let pairing: RemotePairingHost

    private let server: WebSocketServing
    private weak var player: PlayerEngine?
    private weak var library: LibraryStore?

    /// Имя Bonjour-сервиса (имя iPhone). Фоллбэк — «Zver iPhone».
    private let serviceName: String

    /// Активные соединения с их состоянием авторизации. Живёт на `@MainActor`
    /// (все мутации — внутри `Task { @MainActor in }` из сетевых колбэков).
    private var clients: [RemoteClientID: ClientState] = [:]

    /// Последнее отправленное состояние — база для `RemoteStateDiff` (троттлинг).
    private var lastSentState: RemotePlayerState?
    private var cancellables: Set<AnyCancellable> = []

    init(player: PlayerEngine,
         library: LibraryStore,
         server: WebSocketServing = NWWebSocketServer(),
         pairing: RemotePairingHost = RemotePairingHost(),
         serviceName: String = RemoteControlService.defaultServiceName) {
        self.player = player
        self.library = library
        self.server = server
        self.pairing = pairing
        self.serviceName = serviceName
    }

    /// Имя iPhone для Bonjour (`UIDevice.name`, фоллбэк — «Zver iPhone»).
    static var defaultServiceName: String {
        let name = UIDevice.current.name
        return name.isEmpty ? "Zver iPhone" : name
    }

    // MARK: - Жизненный цикл сервера

    /// Включает пульт: поднимает WS-сервер с Bonjour-анонсом `svc=remote` и
    /// подписывается на плеер/библиотеку для пушей. Идемпотентно.
    func enable() {
        guard !isEnabled else { return }
        isEnabled = true

        let txt: [String: String] = [
            "name": serviceName,
            "v": String(RemoteMessage.currentProtocolVersion),
            ServiceTXT.roleKey: ServiceTXT.remote,
        ]
        server.start(
            port: nil,
            name: serviceName,
            txt: txt,
            onClient: { [weak self] handle in
                // Сетевая очередь → @MainActor: учёт клиента и подписка на его поток.
                Task { @MainActor in self?.handleNewClient(handle) }
            },
            onReady: { _ in },
            onFailure: { [weak self] _ in
                Task { @MainActor in self?.disable() }
            }
        )
        observePlayerAndLibrary()
    }

    /// Выключает пульт: гасит сервер (анонс + все соединения), снимает подписки.
    func disable() {
        guard isEnabled else { return }
        isEnabled = false
        server.stop()
        clients.removeAll()
        connectedClients = 0
        lastSentState = nil
        cancellables.removeAll()
    }

    // MARK: - Соединения

    private func handleNewClient(_ handle: RemoteClientHandle) {
        let id = handle.id
        clients[id] = ClientState()
        handle.onMessage { [weak self] message in
            Task { @MainActor in self?.handleMessage(message, from: id) }
        }
        handle.onClose { [weak self] in
            Task { @MainActor in self?.handleClose(id) }
        }
    }

    private func handleClose(_ id: RemoteClientID) {
        if let state = clients.removeValue(forKey: id), state.authorized {
            connectedClients = max(connectedClients - 1, 0)
        }
    }

    private func handleMessage(_ message: RemoteMessage, from id: RemoteClientID) {
        guard var client = clients[id] else { return }

        // До авторизации принимаем только pair/hello; всё остальное игнорируем.
        if !client.authorized {
            switch message.payload {
            case let .pair(code):
                handlePair(code: code, clientId: id, client: &client)
            case let .hello(token):
                handleHello(token: token, clientId: id, client: &client)
            default:
                break // команды до авторизации молча отбрасываем
            }
            clients[id] = client
            return
        }

        // Авторизованный клиент: команды транспорта и запросы библиотеки.
        handleAuthorizedCommand(message.payload, clientId: id)
    }

    // MARK: - Авторизация

    private func handlePair(code: String, clientId id: RemoteClientID, client: inout ClientState) {
        guard let token = pairing.verifyPairing(code: code) else {
            server.send(RemoteMessage(payload: .error(message: "pairing failed")), to: id)
            return
        }
        client.authorized = true
        connectedClients += 1
        server.send(RemoteMessage(payload: .paired(token: token)), to: id)
        sendInitialState(to: id)
    }

    private func handleHello(token: String, clientId id: RemoteClientID, client: inout ClientState) {
        let ok = pairing.verify(token: token)
        server.send(
            RemoteMessage(payload: .helloAck(ok: ok,
                                             protocolVersion: RemoteMessage.currentProtocolVersion)),
            to: id
        )
        guard ok else { return }
        client.authorized = true
        connectedClients += 1
        sendInitialState(to: id)
    }

    /// После авторизации: лёгкий список альбомов + текущий снимок плеера.
    private func sendInitialState(to id: RemoteClientID) {
        if let library {
            let lib = RemoteLibraryBuilder.library(from: library.albums)
            server.send(RemoteMessage(payload: .library(lib)), to: id)
        }
        if let state = currentPlayerState() {
            server.send(RemoteMessage(payload: .state(state)), to: id)
        }
    }

    // MARK: - Команды авторизованного клиента

    private func handleAuthorizedCommand(_ payload: RemotePayload, clientId id: RemoteClientID) {
        guard let player else { return }
        switch payload {
        case .play:
            // «play» от пульта — возобновление с текущей позиции.
            player.resume()
        case .pause:
            player.pause()
        case .togglePlayPause:
            player.togglePlayPause()
        case .next:
            player.next()
        case .previous:
            player.previous()
        case let .seek(seconds):
            player.seek(to: seconds)
        case .requestLibrary:
            if let library {
                let lib = RemoteLibraryBuilder.library(from: library.albums)
                server.send(RemoteMessage(payload: .library(lib)), to: id)
            }
        case let .requestAlbumTracks(albumId):
            let tracks = library.map {
                RemoteLibraryBuilder.tracks(forAlbumId: albumId, in: $0.albums)
            } ?? []
            server.send(
                RemoteMessage(payload: .albumTracks(albumId: albumId, tracks: tracks)),
                to: id
            )
        case let .playAlbum(albumId, startIndex):
            handlePlayAlbum(albumId: albumId, startIndex: startIndex)
        // Ответные/пуш-варианты, hello/pair (уже авторизованы) и unknown —
        // от Мака не ожидаются: молча игнорируем (forward-compat).
        case .pair, .hello, .paired, .helloAck, .state, .library, .albumTracks,
             .error, .unknown:
            break
        }
    }

    private func handlePlayAlbum(albumId: String, startIndex: Int) {
        guard let player, let library else { return }
        guard let resolved = RemoteLibraryBuilder.resolvePlayAlbum(
            albumId: albumId,
            startIndex: startIndex,
            in: library.albums
        ) else { return }
        player.play(tracks: resolved.tracks, startAt: resolved.startIndex)
    }

    // MARK: - Наблюдение плеера/библиотеки → пуш

    private func observePlayerAndLibrary() {
        guard let player, let library else { return }

        // Любое изменение состояния плеера (трек/playback/очередь/позиция) →
        // диф → broadcast только при значимом изменении (троттлинг позиции).
        let stateTrigger = Publishers.Merge3(
            player.$state.map { _ in () },
            player.$queue.map { _ in () },
            player.$currentTime.map { _ in () }
        )
        stateTrigger
            .sink { [weak self] in self?.broadcastStateIfChanged() }
            .store(in: &cancellables)

        // Изменение каталога → свежий список альбомов всем авторизованным.
        library.$albums
            .dropFirst() // начальный снимок уходит в sendInitialState на коннект
            .sink { [weak self] groups in
                self?.broadcastLibrary(RemoteLibraryBuilder.library(from: groups))
            }
            .store(in: &cancellables)
    }

    private func broadcastStateIfChanged() {
        guard let next = currentPlayerState() else { return }
        guard RemoteStateDiff.shouldEmit(prev: lastSentState,
                                         next: next,
                                         positionThreshold: Self.positionThreshold) else {
            return
        }
        lastSentState = next
        broadcastToAuthorized(RemoteMessage(payload: .state(next)))
    }

    private func broadcastLibrary(_ library: RemoteLibrary) {
        broadcastToAuthorized(RemoteMessage(payload: .library(library)))
    }

    /// Рассылает сообщение только авторизованным клиентам (адресно, чтобы не
    /// слать состояние ещё-не-авторизованным/в процессе pairing соединениям).
    private func broadcastToAuthorized(_ message: RemoteMessage) {
        for (id, state) in clients where state.authorized {
            server.send(message, to: id)
        }
    }

    /// Снимок текущего состояния плеера в DTO протокола, либо nil (нет ссылки).
    private func currentPlayerState() -> RemotePlayerState? {
        guard let player else { return nil }
        let q = player.queue
        let remoteQueue = q.tracks.map(RemoteLibraryBuilder.remoteTrack(from:))
        let current = q.current.map(RemoteLibraryBuilder.remoteTrack(from:))
        return RemotePlayerState(
            playback: Self.playback(from: player.state),
            current: current,
            position: player.currentTime,
            queue: remoteQueue,
            currentIndex: q.currentIndex
        )
    }

    private static func playback(from state: PlayerEngine.State) -> RemotePlayback {
        switch state {
        case .idle: return .idle
        case .playing: return .playing
        case .paused: return .paused
        }
    }

    /// Состояние одного соединения на стороне сервиса (только авторизация).
    private struct ClientState {
        var authorized = false
    }
}
