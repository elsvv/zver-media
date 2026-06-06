import MediaPlayer
import UIKit
import ZverCore

/// Мост к системным интерфейсам воспроизведения: локскрин/Control Center
/// (MPNowPlayingInfoCenter) и пульт (MPRemoteCommandCenter).
@MainActor
final class NowPlayingService {
    /// Пара команда + токен addTarget. @unchecked Sendable — чтобы nonisolated
    /// deinit мог прочитать массив и передать его в MainActor-задачу;
    /// сами значения нигде не мутируются, removeTarget зовём на MainActor.
    private struct CommandRegistration: @unchecked Sendable {
        let command: MPRemoteCommand
        let token: Any
    }

    /// Токены addTarget: MPRemoteCommandCenter — глобальный синглтон процесса,
    /// без removeTarget обработчики остаются в нём навсегда.
    private var commandTargets: [CommandRegistration] = []

    deinit {
        // deinit nonisolated — снимаем обработчики через хоп на MainActor.
        let targets = commandTargets
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            for registration in targets {
                registration.command.removeTarget(registration.token)
            }
        }
    }

    func wire(to engine: PlayerEngine) {
        // Идемпотентность: повторный wire (новый PlayerEngine в превью/тестах)
        // не должен наслаивать дубли обработчиков в глобальном центре команд.
        unwire()
        let cc = MPRemoteCommandCenter.shared()
        // [weak engine] — иначе глобальный центр команд удерживал бы движок
        // вечно. Обработчики приходят на главном потоке, но без аннотации
        // MainActor — assumeIsolated даёт синхронный вызов движка
        // и корректный возврат статуса.
        register(cc.playCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            MainActor.assumeIsolated { engine.resume() }
            return .success
        }
        register(cc.pauseCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            MainActor.assumeIsolated { engine.pause() }
            return .success
        }
        register(cc.nextTrackCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            MainActor.assumeIsolated { engine.next() }
            return .success
        }
        register(cc.previousTrackCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            MainActor.assumeIsolated { engine.previous() }
            return .success
        }
        register(cc.changePlaybackPositionCommand) { [weak engine] event in
            guard let engine,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            // event не Sendable — в изолированное замыкание передаём только Double.
            let position = event.positionTime
            MainActor.assumeIsolated { engine.seek(to: position) }
            return .success
        }
    }

    func unwire() {
        for registration in commandTargets {
            registration.command.removeTarget(registration.token)
        }
        commandTargets.removeAll()
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        commandTargets.append(
            CommandRegistration(command: command, token: command.addTarget(handler: handler))
        )
    }

    /// Обновлять при смене трека, play/pause и seek — НЕ по таймеру:
    /// системе достаточно elapsed + rate, позицию она экстраполирует сама.
    func update(track: Track, artwork: UIImage?, currentTime: Double, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist ?? "",
            MPMediaItemPropertyAlbumTitle: track.album ?? "",
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork {
            // @Sendable обязателен: иначе замыкание, созданное в @MainActor-методе,
            // наследует изоляцию MainActor, а MediaPlayer вызывает requestHandler
            // на своей фоновой accessQueue при сериализации Now Playing →
            // dispatch_assert_queue_fail (SIGTRAP). UIImage иммутабелен и Sendable.
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: artwork.size) { @Sendable _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
