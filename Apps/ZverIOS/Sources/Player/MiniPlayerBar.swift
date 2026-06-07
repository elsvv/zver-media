import SwiftUI
import ZverCore

/// Мини-плеер над нижним краем (как в Apple Music): миниатюра обложки,
/// название трека, play/pause и тонкая линия прогресса сверху.
/// Тап по полоске открывает полноэкранный плеер.
struct MiniPlayerBar: View {
    @ObservedObject var engine: PlayerEngine

    @State private var artwork: UIImage?
    @State private var showsPlayerScreen = false

    var body: some View {
        if let track = engine.queue.current {
            VStack(spacing: 0) {
                progressLine(for: track)
                HStack(spacing: 12) {
                    artworkThumbnail
                    Text(track.title)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        engine.togglePlayPause()
                    } label: {
                        Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(engine.state == .playing ? "Пауза" : "Играть")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture { showsPlayerScreen = true }
            .task(id: track.id) {
                // Сначала синхронный peek в кэш: без сброса в nil нет
                // мигания плейсхолдером при смене трека.
                if let cached = engine.artworkLoader.cached(for: track) {
                    artwork = cached
                    return
                }
                artwork = nil
                let image = await engine.artworkLoader.artwork(for: track)
                // Отменённая задача (смена трека) не должна перетирать артворк:
                // её continuation всё равно выполняется после await.
                if !Task.isCancelled { artwork = image }
            }
            .sheet(isPresented: $showsPlayerScreen) {
                PlayerScreen(engine: engine)
            }
        }
    }

    private var artworkThumbnail: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func progressLine(for track: Track) -> some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(.tint)
                .frame(width: proxy.size.width * progressFraction(for: track))
        }
        .frame(height: 2)
        .background(.quaternary)
    }

    private func progressFraction(for track: Track) -> CGFloat {
        guard track.duration > 0 else { return 0 }
        return CGFloat(min(max(engine.currentTime / track.duration, 0), 1))
    }
}
