import Foundation
import Combine
import ZverTransport

/// Агрегатор принятого от iPhone состояния пульта для UI окна «Пульт» (S5-8).
///
/// `@MainActor ObservableObject`: координатор (`RemoteClientCoordinator`) на
/// каждое декодированное `state`/`library`/`albumTracks` зовёт `apply(_:)` уже
/// на главном потоке (переход с сетевой очереди делает координатор через
/// `Task { @MainActor in … }`), а SwiftUI-вью биндятся к `@Published`.
///
/// Здесь же — интерполяция позиции между пушами: iPhone троттлит пуши позиции
/// (`RemoteStateDiff`), Mac между ними сам «крутит» секундомер по локальному
/// времени, пока `playback == .playing`. `displayPosition` отдаёт текущую оценку.
@MainActor
final class RemoteClientStore: ObservableObject {
    /// Последний принятый снимок состояния плеера (трек/playback/очередь/индекс).
    /// Позиция в нём — на момент пуша; для UI используйте `displayPosition`.
    @Published private(set) var playerState: RemotePlayerState?
    /// Список альбомов библиотеки iPhone (лёгкий, без треков).
    @Published private(set) var library: RemoteLibrary?
    /// Кэш треков по `albumId` — заполняется ответами `albumTracks` на запрос
    /// раскрытия альбома. UI читает по ключу выбранного альбома.
    @Published private(set) var albumTracks: [String: [RemoteTrack]] = [:]
    /// Последний агрегированный статус headless-импорта, запущенного с ЭТОГО Мака
    /// (`startImport`). Пуш от iPhone; вкладка «Синк» рисует стадию/долю. nil —
    /// импорт с Мака в этой сессии не запускался (или сброшен на дисконнекте).
    @Published private(set) var importStatus: RemoteImportStatus?
    /// Последняя ошибка протокола от iPhone (`error{message}`) — для тоста/баннера.
    @Published private(set) var lastError: String?

    /// Базовая позиция последнего пуша и момент её приёма — основа интерполяции.
    private var positionBaseline: Double = 0
    private var positionBaselineAt: Date = .distantPast

    init() {}

    // MARK: - Приём сообщений (вызывается уже на @MainActor)

    /// Применяет одно входящее сообщение к состоянию UI. Неизвестные/служебные
    /// варианты (pair/hello/...) сюда не доходят — их разбирает координатор;
    /// здесь только пуши iPhone → Mac.
    func apply(_ message: RemoteMessage) {
        switch message.payload {
        case let .state(state):
            applyState(state)
        case let .library(library):
            self.library = library
        case let .albumTracks(albumId, tracks):
            albumTracks[albumId] = tracks
        case let .importStatus(status):
            importStatus = status
        case let .error(message):
            lastError = message
        default:
            // helloAck/paired разбирает координатор; команды Mac→iPhone сюда не
            // приходят; .unknown — forward-compat, молча игнорируем.
            break
        }
    }

    /// Принимает свежий снимок состояния: сохраняет и сбрасывает базу интерполяции
    /// позиции на момент приёма.
    func applyState(_ state: RemotePlayerState) {
        playerState = state
        positionBaseline = state.position
        positionBaselineAt = Date()
    }

    // MARK: - Интерполяция позиции

    /// Текущая оценка позиции воспроизведения в секундах: при `playing` —
    /// `baseline + (now - baselineAt)`, иначе застывшая `baseline`. Ограничена
    /// длительностью трека, если она известна.
    var displayPosition: Double {
        guard let state = playerState else { return 0 }
        let base = positionBaseline
        guard state.playback == .playing else { return base }
        let elapsed = Date().timeIntervalSince(positionBaselineAt)
        let estimate = base + max(0, elapsed)
        if let duration = state.current?.duration, duration > 0 {
            return min(estimate, duration)
        }
        return estimate
    }

    /// Признак активного воспроизведения — для запуска/останова UI-таймера
    /// интерполяции в окне пульта (S5-8).
    var isPlaying: Bool {
        playerState?.playback == .playing
    }

    // MARK: - Жизненный цикл

    /// Сбрасывает агрегированное состояние (потеря соединения / смена iPhone).
    /// Библиотеку и кэш треков тоже чистим — они принадлежат конкретному iPhone.
    func reset() {
        playerState = nil
        library = nil
        albumTracks = [:]
        importStatus = nil
        lastError = nil
        positionBaseline = 0
        positionBaselineAt = .distantPast
    }

    /// Сбрасывает только баннер ошибки (после показа пользователю).
    func clearError() {
        lastError = nil
    }
}
