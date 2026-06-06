import SwiftUI
import ZverCore
import ZverMetadata

/// Временная обвязка для ручной проверки PlayerEngine:
/// скан Documents → список треков → тап → воспроизведение.
struct ContentView: View {
    @StateObject private var engine = PlayerEngine()
    @State private var tracks: [Track] = []
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            List(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    engine.play(tracks: tracks, startAt: index)
                } label: {
                    VStack(alignment: .leading) {
                        Text(track.title)
                        Text(track.artist ?? "Неизвестный артист")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Zver")
            .toolbar {
                Button(isScanning ? "Сканирую…" : "Сканировать") {
                    Task { await scan() }
                }
                .disabled(isScanning)
            }
            .safeAreaInset(edge: .bottom) {
                if engine.state != .idle {
                    playbackBar
                }
            }
        }
    }

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

    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        let infos = (try? await LibraryScanner.scan(directory: URL.documentsDirectory)) ?? []
        tracks = infos.map(makeTrack)
    }

    private func makeTrack(_ info: AudioFileInfo) -> Track {
        Track(url: info.url,
              title: info.title,
              artist: info.artist,
              album: info.album,
              trackNumber: info.trackNumber,
              year: info.year,
              duration: info.duration,
              sampleRate: info.sampleRate,
              bitDepth: info.bitDepth)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
