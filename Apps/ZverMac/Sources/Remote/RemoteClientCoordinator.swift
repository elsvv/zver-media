import Foundation
import Combine
import ZverTransport

/// `@MainActor`-координатор пульта на Маке: browse `_zver._tcp svc=remote` →
/// выбор iPhone → WebSocket-подключение → авторизация (`hello{token}` или
/// сопряжение `pair{code}` → `paired{token}`) → приём состояния/библиотеки и
/// отправка команд транспорта/браузинга.
///
/// Зеркало `ServerCoordinator`/`MacSyncClient` этапа 3, роли перевёрнуты: там Mac
/// был сервером/хостом, здесь — КЛИЕНТ. Рантайм-сеть спрятана за протоколами
/// `ServiceBrowser`/`WebSocketClient` (юнит-тестами не покрывается — лессон
/// прошлых этапов); тестируемая логика (диф/кодек/фильтр роли/проверка токена)
/// живёт в `ZverTransport`.
///
/// Concurrency (краш-класс Swift 6): все колбэки браузера и WS-клиента —
/// `@Sendable`, приходят на сетевой очереди, НЕ наследуют `@MainActor`. Переход в
/// эту модель — строго через `Task { @MainActor in … }`. Сами `WebSocketClient`/
/// `ServiceBrowser` — `Sendable`-объекты, безопасны для вызова из любой изоляции.
@MainActor
final class RemoteClientCoordinator: ObservableObject {
    /// Статус пульта для UI (S5-8). `Equatable` — упрощает реакцию вью.
    enum Status: Equatable {
        /// Пульт выключен / ещё не запускали browse.
        case idle
        /// Идёт поиск iPhone в сети (browse запущен, подходящих сервисов нет).
        case discovering
        /// Найдены пульт-сервисы iPhone, ни один пока не выбран/не подключён.
        case discovered
        /// Идёт сопряжение по коду (ожидаем ввод кода и/или ответ `paired`).
        case pairing
        /// Соединение установлено и авторизовано (`helloAck{ok:true}`) — командуем.
        case connected
        /// iPhone не в сети / соединение упало — деградация с переподключением.
        case offline
        /// Сетевая/авторизационная ошибка с RU-описанием.
        case failed(String)
    }

    // MARK: - Публикуемое состояние для UI

    @Published private(set) var status: Status = .idle
    /// Текущий список обнаруженных пульт-сервисов iPhone (`svc=remote`).
    @Published private(set) var devices: [DiscoveredService] = []
    /// Имя выбранного для подключения iPhone (сервис Bonjour/Keychain).
    @Published private(set) var selectedDeviceName: String?
    /// Требуется ли ввод кода сопряжения (нет сохранённого токена для iPhone).
    @Published private(set) var needsPairingCode = false

    /// Агрегатор принятого состояния/библиотеки для вью пульта.
    let store: RemoteClientStore

    /// Кэш обложек альбомов (грид библиотеки + now-playing пульта). Промах диска
    /// тянет обложку через `requestArtwork`; входящий `.artwork` кладётся сюда.
    let artwork = AlbumArtworkStore()

    /// Соединение установлено и авторизовано — можно слать команды/запускать синк.
    var isConnected: Bool { status == .connected }

    // MARK: - Зависимости (рантайм-сеть за протоколами)

    private let browser: ServiceBrowser
    private let client: WebSocketClient
    private let pairing: RemotePairingClient
    /// Запускать ли реальный browse/WS (false — модель без сети для превью/тестов).
    private let autoStart: Bool

    /// iPhone, с которым сейчас установлена/устанавливается сессия.
    private var connectingDeviceName: String?
    /// Монотонный id активной попытки соединения. Каждый `connect`/`goOffline`/
    /// `stop` инкрементит его; колбэки клиента захватывают своё поколение, и
    /// обработчик отбрасывает хвосты устаревшей/заменённой сессии. Защита от
    /// гонки re-connect к ТОМУ ЖЕ iPhone: `NWWebSocketClient.connect()` первым
    /// делом синхронно `disconnect()`-ит старую сессию, та шлёт `.disconnected`;
    /// проверки только по имени недостаточно (имя совпадает) — устаревший
    /// `.disconnected` порвал бы свежесозданную сессию через `goOffline()`.
    private var sessionGeneration = 0
    /// Авторизация прошла (`helloAck{ok:true}`) — команды разрешены.
    private var isAuthorized = false

    init(browser: ServiceBrowser = NWServiceBrowser(),
         client: WebSocketClient = NWWebSocketClient(),
         pairing: RemotePairingClient = RemotePairingClient(),
         store: RemoteClientStore = RemoteClientStore(),
         autoStart: Bool = true) {
        self.browser = browser
        self.client = client
        self.pairing = pairing
        self.store = store
        self.autoStart = autoStart
        // Промах кэша обложек → сетевой запрос iPhone. Замыкание держит weak self,
        // чтобы кэш не удерживал координатор.
        artwork.onNeedArtwork = { [weak self] albumId in
            self?.requestArtwork(albumId: albumId)
        }
    }

    // MARK: - Жизненный цикл browse

    /// Запускает поиск пультов iPhone в сети. Колбэк браузера `@Sendable` на
    /// сетевой очереди → прыгаем на `@MainActor`.
    func startDiscovery() {
        guard autoStart else { return }
        if status == .idle { status = .discovering }

        browser.start { @Sendable [weak self] services in
            // Браузер отдаёт ВСЕ `_zver._tcp` (и синк-сервис Мака, и пульт iPhone);
            // фильтруем по роли через computed `DiscoveredService.role` (отсутствие
            // `svc` → `sync`, см. `ServiceRole.swift`), чтобы не путать пульт iPhone
            // с синк-сервисом Мака на общем типе Bonjour.
            let remotes = services.filter { $0.role == ServiceTXT.remote }
            Task { @MainActor [weak self] in
                self?.handleDiscovered(remotes)
            }
        }
    }

    /// Полностью останавливает пульт: browse, соединение, статус → idle.
    func stop() {
        sessionGeneration += 1
        browser.stop()
        client.disconnect()
        connectingDeviceName = nil
        selectedDeviceName = nil
        isAuthorized = false
        needsPairingCode = false
        store.reset()
        artwork.reset()
        devices = []
        status = .idle
    }

    /// Обновляет список устройств и согласует статус/переподключение.
    private func handleDiscovered(_ remotes: [DiscoveredService]) {
        devices = remotes

        // Если подключённый/подключаемый iPhone пропал из сети — деградация.
        if let connecting = connectingDeviceName,
           !remotes.contains(where: { $0.name == connecting }) {
            goOffline()
            return
        }

        // Целевой iPhone вернулся в сеть после offline — переподключаемся.
        if status == .offline, let selected = selectedDeviceName,
           let device = remotes.first(where: { $0.name == selected }) {
            connect(to: device)
            return
        }

        // Обновляем «поисковый» статус, пока никого не выбрали.
        if connectingDeviceName == nil && !isAuthorized {
            status = remotes.isEmpty ? .discovering : .discovered
        }
    }

    // MARK: - Выбор устройства и подключение

    /// Выбирает iPhone и инициирует подключение: если в Keychain есть токен —
    /// `hello{token}`; иначе ждём ввод кода (`needsPairingCode = true`).
    func select(_ device: DiscoveredService) {
        selectedDeviceName = device.name
        connect(to: device)
    }

    /// Устанавливает WebSocket-соединение и готовит авторизацию. Колбэки клиента
    /// `@Sendable` на сетевой очереди → прыгаем на `@MainActor`.
    private func connect(to device: DiscoveredService) {
        let name = device.name
        sessionGeneration += 1
        let generation = sessionGeneration
        connectingDeviceName = name
        selectedDeviceName = name
        isAuthorized = false
        needsPairingCode = false
        status = .discovered

        client.connect(
            to: device,
            onMessage: { @Sendable [weak self] message in
                Task { @MainActor [weak self] in
                    self?.handleIncoming(message, fromDevice: name, generation: generation)
                }
            },
            onState: { @Sendable [weak self] connectionState in
                Task { @MainActor [weak self] in
                    self?.handleConnectionState(connectionState, device: device, generation: generation)
                }
            }
        )
    }

    /// Реакция на смену состояния WebSocket-соединения.
    private func handleConnectionState(_ connectionState: WebSocketConnectionState,
                                       device: DiscoveredService,
                                       generation: Int) {
        // Игнорируем хвосты от уже отменённой/устаревшей/заменённой сессии
        // (см. `sessionGeneration`): только поколение точно отделяет колбэки
        // текущей попытки от синхронного `.disconnected` предыдущей сессии того
        // же iPhone при re-connect.
        guard generation == sessionGeneration else { return }

        switch connectionState {
        case .connecting:
            break
        case .ready:
            // Handshake готов: либо здороваемся токеном, либо просим код.
            if let token = pairing.token(forDevice: device.name) {
                client.send(pairing.helloMessage(token: token))
            } else {
                needsPairingCode = true
                status = .pairing
            }
        case .disconnected, .failed:
            goOffline()
        }
    }

    // MARK: - Сопряжение по коду

    /// Отправляет введённый пользователем код iPhone (`pair{code}`). Ответ
    /// `paired{token}` придёт в `handleIncoming` → сохраним токен и пошлём `hello`.
    func submitPairingCode(_ code: String) {
        guard connectingDeviceName != nil else { return }
        status = .pairing
        client.send(pairing.pairMessage(code: code))
    }

    // MARK: - Входящие сообщения

    /// Разбор входящего `RemoteMessage`. Авторизация (`paired`/`helloAck`) —
    /// здесь; пуши состояния/библиотеки делегируются `store`.
    private func handleIncoming(_ message: RemoteMessage, fromDevice name: String, generation: Int) {
        guard generation == sessionGeneration else { return }

        switch message.payload {
        case let .paired(token):
            // Верный код → iPhone выпустил токен: кладём в Keychain и здороваемся.
            pairing.persistToken(token, forDevice: name)
            needsPairingCode = false
            client.send(pairing.helloMessage(token: token))

        case let .helloAck(ok, _):
            if ok {
                isAuthorized = true
                needsPairingCode = false
                status = .connected
                // На коннект iPhone сам шлёт library + state; на всякий случай
                // дозапрашиваем библиотеку.
                client.send(RemoteMessage(payload: .requestLibrary))
            } else {
                // iPhone отозвал токен — забываем и просим новый код.
                pairing.forgetToken(forDevice: name)
                needsPairingCode = true
                status = .pairing
            }

        case let .artwork(albumId, data):
            // Обложка — в кэш (не в store): грид/now-playing читают `artwork`.
            artwork.ingest(albumId: albumId, data: data)

        case .error:
            // Протокольная ошибка от iPhone — отдаём в store для баннера, статус
            // не роняем (соединение живо).
            store.apply(message)

        default:
            // Пуши state/library/albumTracks/importStatus — в агрегатор UI.
            store.apply(message)
        }
    }

    // MARK: - Деградация / переподключение

    /// Переводит в offline («iPhone не в сети»): закрывает соединение, сбрасывает
    /// авторизацию, чистит агрегированное состояние. browse продолжает работать —
    /// при возврате iPhone `handleDiscovered` переподключится.
    private func goOffline() {
        sessionGeneration += 1
        client.disconnect()
        connectingDeviceName = nil
        isAuthorized = false
        needsPairingCode = false
        store.reset()
        artwork.reset()
        status = .offline
    }

    /// Ручное переподключение из UI (кнопка «Переподключиться» на заглушке).
    func reconnect() {
        guard let name = selectedDeviceName,
              let device = devices.first(where: { $0.name == name }) else {
            status = devices.isEmpty ? .discovering : .discovered
            return
        }
        connect(to: device)
    }

    // MARK: - Отправка команд (только после авторизации)

    /// Шлёт команду транспорта/браузинга iPhone, если соединение авторизовано.
    /// До авторизации команды глотаются (iPhone их всё равно проигнорирует).
    func send(_ command: RemotePayload) {
        guard isAuthorized else { return }
        client.send(RemoteMessage(payload: command))
    }

    // Тонкие фасады команд для вью пульта (S5-8) — читаемость на месте вызова.
    func play() { send(.play) }
    func pause() { send(.pause) }
    func togglePlayPause() { send(.togglePlayPause) }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func seek(to seconds: Double) { send(.seek(seconds: seconds)) }
    func requestLibrary() { send(.requestLibrary) }
    func requestAlbumTracks(albumId: String) { send(.requestAlbumTracks(albumId: albumId)) }
    func playAlbum(albumId: String, startIndex: Int) {
        send(.playAlbum(albumId: albumId, startIndex: startIndex))
    }
    /// Запускает headless-импорт с этого Мака на iPhone (Мак спарен/авторизован).
    /// Прогресс придёт пушами `importStatus` → `store.importStatus`.
    func startImport() { send(.startImport) }
    /// Просит обложку альбома у iPhone (зовётся кэшом на промахе диска).
    func requestArtwork(albumId: String) { send(.requestArtwork(albumId: albumId)) }
}
