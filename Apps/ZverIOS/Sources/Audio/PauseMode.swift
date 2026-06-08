import Foundation

/// Режим поведения плеера на паузе — настройка пульта (этап 5).
///
/// - `.alwaysConnected` («всегда на связи»): на паузе основной `player.pause()`
///   (позиция сохраняется), но движок продолжает крутить keep-alive-ноду с
///   тишиной нулевыми сэмплами. iOS не усыпляет приложение (background audio
///   жив, аудиосессия активна, ЦАП захвачен) → WebSocket-сервер пульта
///   продолжает обслуживать команды с Мака мгновенно, без оживления с
///   локскрина.
/// - `.economical` («экономный»): поведение этапов 1–4 без изменений — на
///   паузе движок останавливается, приложение со временем суспендится, пульт
///   слепнет; команды снова доходят при оживлении с локскрина/Control Center
///   (MPRemoteCommandCenter).
enum PauseMode: String, CaseIterable, Sendable {
    case alwaysConnected
    case economical

    /// Дефолт MVP — экономный режим (как до этапа 5), keep-alive выключен.
    static let `default`: PauseMode = .economical
}

extension PauseMode {
    /// Чистое решение: нужен ли keep-alive (зацикленная тишина) при ПЕРЕХОДЕ В
    /// ПАУЗУ в этом режиме. Вынесено отдельно от `AVAudioEngine`, чтобы решение
    /// было проверяемо без рантайма аудио.
    ///
    /// Keep-alive нужен ровно в режиме «всегда на связи»: только так приложение
    /// остаётся активным на паузе и пульт продолжает принимать команды. В
    /// экономном режиме keep-alive не запускается никогда.
    var needsKeepAliveOnPause: Bool {
        switch self {
        case .alwaysConnected: return true
        case .economical: return false
        }
    }
}

/// Персистентное хранилище режима паузы в `UserDefaults`. Изолировано от
/// `PlayerEngine`, чтобы и плеер, и экран Настроек читали/писали один ключ.
struct PauseModeStore {
    static let defaultsKey = "zver.pauseMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Текущий режим из `UserDefaults`; при отсутствии/мусоре — `.default`.
    func load() -> PauseMode {
        guard let raw = defaults.string(forKey: Self.defaultsKey),
              let mode = PauseMode(rawValue: raw) else {
            return .default
        }
        return mode
    }

    func save(_ mode: PauseMode) {
        defaults.set(mode.rawValue, forKey: Self.defaultsKey)
    }
}
