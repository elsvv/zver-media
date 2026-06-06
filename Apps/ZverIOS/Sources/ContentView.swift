import SwiftUI
import ZverCore

struct ContentView: View {
    @StateObject private var engine = PlayerEngine()
    @StateObject private var library = LibraryStore()

    var body: some View {
        NavigationStack {
            LibraryView(store: library, engine: engine)
                .safeAreaInset(edge: .bottom) {
                    if engine.state != .idle {
                        playbackBar
                    }
                }
        }
    }

    /// Временная панель управления — заменится на MiniPlayerBar в Task 12.
    private var playbackBar: some View {
        HStack(spacing: 24) {
            Text(engine.queue.current?.title ?? "")
                .lineLimit(1)
            Spacer()
            Text(formatTime(engine.currentTime))
                .font(.caption.monospacedDigit())
            Button { engine.previous() } label: { Image(systemName: "backward.fill") }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.state == .playing ? "pause.fill" : "play.fill")
            }
            Button { engine.next() } label: { Image(systemName: "forward.fill") }
        }
        .padding()
        .background(.thinMaterial)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
