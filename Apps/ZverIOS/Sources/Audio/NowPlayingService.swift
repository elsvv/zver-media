import MediaPlayer
import UIKit
import ZverCore

/// Мост к системным интерфейсам воспроизведения: локскрин/Control Center
/// (MPNowPlayingInfoCenter) и пульт (MPRemoteCommandCenter).
@MainActor
final class NowPlayingService {
    func wire(to engine: PlayerEngine) {
        let cc = MPRemoteCommandCenter.shared()
        // Обработчики команд приходят на главном потоке, но без аннотации
        // MainActor — assumeIsolated даёт синхронный вызов движка
        // и корректный возврат статуса.
        cc.playCommand.addTarget { _ in
            MainActor.assumeIsolated { engine.resume() }
            return .success
        }
        cc.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { engine.pause() }
            return .success
        }
        cc.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { engine.next() }
            return .success
        }
        cc.previousTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { engine.previous() }
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            MainActor.assumeIsolated { engine.seek(to: event.positionTime) }
            return .success
        }
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
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
