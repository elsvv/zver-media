import SwiftUI
import ZverCore

/// Полноэкранный плеер (sheet): крупный артворк, title/artist/album,
/// бейдж формата («FLAC 24/96»), слайдер с seek по отпусканию
/// и транспортные кнопки. Свайп вниз закрывает (системное поведение sheet).
struct PlayerScreen: View {
    @ObservedObject var engine: PlayerEngine
    @Environment(\.dismiss) private var dismiss

    @State private var artwork: UIImage?
    /// Во время драга слайдера показываем целевое время, а не позицию движка;
    /// seek выполняется один раз по отпусканию (onEditingChanged → false).
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    var body: some View {
        Group {
            if let track = engine.queue.current {
                content(for: track)
                    .task(id: track.id) {
                        artwork = nil
                        artwork = await engine.artworkLoader.artwork(for: track)
                    }
            }
        }
        .presentationDragIndicator(.visible)
        .onChange(of: engine.queue.current) { _, current in
            // Очередь закончилась — пустой шторке висеть незачем.
            if current == nil { dismiss() }
        }
    }

    private func content(for track: Track) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            artworkView
            trackInfo(track)
            VStack(spacing: 8) {
                progressSlider(for: track)
                timeLabels(for: track)
            }
            transportControls
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private var artworkView: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
    }

    private func trackInfo(_ track: Track) -> some View {
        VStack(spacing: 6) {
            Text(track.title)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            if let artist = track.artist {
                Text(artist)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let album = track.album {
                Text(album)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(formatBadge(for: track))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .multilineTextAlignment(.center)
    }

    private func progressSlider(for track: Track) -> some View {
        Slider(
            value: Binding(
                get: { isScrubbing ? scrubTime : min(engine.currentTime, track.duration) },
                set: { scrubTime = $0 }
            ),
            in: 0...max(track.duration, 0.01)
        ) { editing in
            if editing {
                scrubTime = engine.currentTime
                isScrubbing = true
            } else {
                engine.seek(to: scrubTime)
                isScrubbing = false
            }
        }
    }

    private func timeLabels(for track: Track) -> some View {
        let displayed = isScrubbing ? scrubTime : engine.currentTime
        return HStack {
            Text(formatTime(displayed))
            Spacer()
            Text("-" + formatTime(max(track.duration - displayed, 0)))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var transportControls: some View {
        HStack(spacing: 56) {
            Button { engine.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
            }
            Button { engine.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    /// «FLAC 24/96»: расширение верхним регистром, битность (если есть) и частота в kHz.
    private func formatBadge(for track: Track) -> String {
        let kHz = track.sampleRate / 1000
        let rate = kHz == kHz.rounded() ? String(Int(kHz)) : String(format: "%.1f", kHz)
        let ext = track.fileExtension.uppercased()
        if let bitDepth = track.bitDepth {
            return "\(ext) \(bitDepth)/\(rate)"
        }
        return "\(ext) \(rate)"
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
