import Foundation
import Combine
import ZverTransport

/// `@MainActor`-координатор сетевой раздачи: связывает исходящую очередь,
/// файловый сервер, sync-host и pairing-контроллер.
///
/// Запускает `FileServer` при непустой очереди; сервер сам публикует `_zver._tcp`
/// на ТОМ ЖЕ `NWListener`, что слушает соединения (один слушатель и принимает, и
/// анонсирует — так задумано в Network.framework; второй слушатель на том же
/// порту дал бы EADDRINUSE). Пустеет очередь — сервер и анонс останавливаются.
/// Все сетевые колбэки (`onReady`/`onConfirm`/`onTokenIssued`) — `@Sendable`,
/// переход в эту `@MainActor`-модель делается через `Task { @MainActor in … }`
/// (краш-класс Swift 6: не наследуем UI-изоляцию в сетевые очереди).
///
/// На ЭТОЙ машине раздачу не гоняем (только компиляция таргета). `autoStart`
/// позволяет отключить реальный запуск слушателя в превью/тестах сборки.
@MainActor
final class ServerCoordinator: ObservableObject {
    /// Статус раздачи для UI.
    enum Status: Equatable {
        /// Сервер не запущен (очередь пуста или раздача выключена).
        case stopped
        /// Сервер слушает на порту, Bonjour опубликован.
        case running(port: UInt16)
        /// Запуск не удался (RU-описание).
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    /// Контроллер окна сопряжения (6-значный код, выпуск/хранение токена).
    let pairing: PairingHostController

    private let queue: OutgoingQueue
    private let host: SyncHost
    private let fileServer: FileServer
    /// Имя сервиса в Bonjour/TXT (имя Мака).
    private let serviceName: String
    /// Запускать ли реальный `NWListener` (false — только модель, без сети).
    private let autoStart: Bool

    private var cancellables: Set<AnyCancellable> = []
    /// Поколение запуска сервера. Каждый `startIfNeeded`/`stop` его двигает; асинхронный
    /// `onReady`/`onFailure` применяется ТОЛЬКО если поколение не сменилось — иначе
    /// поздний `onReady` от уже остановленного слушателя воскресил бы `.running` с
    /// nil-листенером, и `startIfNeeded` (`if case .running { return }`) больше не
    /// поднял бы сервер (зеркало epoch-guard пульта, коммит 6154e47).
    private var serverEpoch = 0

    init(queue: OutgoingQueue,
         serviceName: String = PairingHostController.defaultServiceName,
         autoStart: Bool = true) {
        let state = HostState()

        // Восстанавливаем ранее выпущенный сессионный токен из Keychain в HostState,
        // чтобы уже спаренный телефон оставался авторизован после перезапуска
        // приложения. Без этого GET /manifest с валидным X-Zver-Token упирался бы в
        // пустой набор токенов → 401 → телефон забывал токен и требовал код заново на
        // КАЖДЫЙ старт Мака (ровно то, ради чего токен зеркалился в Keychain).
        let keyStore = KeychainKeyStore()
        if let savedToken = keyStore.token(forService: serviceName), !savedToken.isEmpty {
            state.registerToken(savedToken)
        }

        let host = SyncHost(queue: queue, state: state)

        self.queue = queue
        self.host = host
        self.serviceName = serviceName
        self.autoStart = autoStart
        self.pairing = PairingHostController(state: state, keyStore: keyStore, serviceName: serviceName)

        // confirm от телефона приходит на сетевой очереди (@Sendable) → прыгаем
        // на @MainActor в модель: снимаем альбом с очереди и пересобираем снимок.
        self.fileServer = FileServer(state: state) { albumId in
            Task { @MainActor in
                host.confirm(albumId: albumId)
            }
        }

        // Выпуск токена при сопряжении (на сетевой очереди) → на @MainActor:
        // зеркалим в Keychain и обновляем UI окна pairing.
        let pairingController = self.pairing
        state.setOnTokenIssued { token in
            Task { @MainActor in
                pairingController.persistIssuedTokenIfNeeded(token)
            }
        }

        // SwiftUI наблюдает только этот объект, но код сопряжения/статус живут во
        // ВЛОЖЕННОМ ObservableObject (`pairing`). Без ретрансляции его изменений
        // появление 6-значного кода (`pairing.open()`) не перерисовывает UI —
        // кнопка «Сопрячь iPhone» нажимается, а цифры не показываются. Пробрасываем
        // objectWillChange вложенного контроллера как свой.
        pairing.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Сервер раздаёт ровно текущую очередь — пересобираем снимок и
        // стартуем/гасим сервер при каждом её изменении.
        observeQueue()
        host.refreshSnapshot()
        syncServerToQueue()
    }

    /// Подписывается на изменения очереди: пересобрать снимок раздачи и
    /// согласовать состояние сервера (старт при непустой / стоп при пустой).
    private func observeQueue() {
        queue.$albums
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.host.refreshSnapshot()
                self.syncServerToQueue()
            }
            .store(in: &cancellables)
    }

    /// Согласует жизненный цикл сервера с наличием альбомов в очереди.
    private func syncServerToQueue() {
        guard autoStart else { return }
        if queue.isEmpty {
            stop()
        } else {
            startIfNeeded()
        }
    }

    /// Стартует сервер (если ещё не запущен). Сервер сам публикует `_zver._tcp`
    /// на своём слушателе (имя Мака + TXT) — без второго bind на тот же порт.
    private func startIfNeeded() {
        if case .running = status { return }

        serverEpoch += 1
        let epoch = serverEpoch
        fileServer.start(
            serviceName: serviceName,
            txt: ["name": serviceName, "v": String(SyncManifest.currentProtocolVersion)],
            onReady: { port in
                // На сетевой очереди → в @MainActor: фиксируем статус (Bonjour
                // уже опубликован самим слушателем до его старта). Игнорируем, если
                // сервер уже остановлен/перезапущен (поколение сменилось).
                Task { @MainActor [weak self] in
                    guard let self, self.serverEpoch == epoch else { return }
                    self.status = .running(port: port)
                }
            },
            onFailure: { _ in
                Task { @MainActor [weak self] in
                    guard let self, self.serverEpoch == epoch else { return }
                    self.status = .failed("Не удалось запустить сервер раздачи.")
                }
            }
        )
    }

    /// Останавливает сервер (со снятием Bonjour-анонса вместе со слушателем) и
    /// закрывает окно сопряжения: иначе UI продолжал бы показывать 6-значный код,
    /// которым телефон уже не достучится (листенер и Bonjour сняты), а одноразовый
    /// код оставался бы взведённым в `HostState`.
    func stop() {
        serverEpoch += 1
        fileServer.stop()
        pairing.close()
        status = .stopped
    }

    /// Открывает окно сопряжения (показывает 6-значный код). Сервер при этом
    /// уже должен слушать (очередь непуста) — иначе телефон не достучится.
    func startPairing() {
        pairing.open()
    }

    /// Закрывает окно сопряжения.
    func stopPairing() {
        pairing.close()
    }
}
