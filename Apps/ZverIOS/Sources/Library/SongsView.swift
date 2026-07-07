import SwiftUI
import ZverCore

/// Раздел «Песни»: список треков секциями по альбомам,
/// тап по треку запускает воспроизведение альбома с него.
struct SongsView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        List(store.albums) { group in
            Section {
                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        // remote-трек (файла нет) тапом качается, а не играет —
                        // плеер этапа 1 не трогаем (см. TrackCloudActions).
                        if track.fileState == .remote {
                            Task { await store.download(track: track) }
                        } else {
                            engine.play(tracks: group.tracks, startAt: index)
                        }
                    } label: {
                        trackRow(track)
                    }
                    .addToPlaylistMenu(for: track, store: store)
                    .cloudActions(for: track, store: store)
                }
            } header: {
                albumHeader(group)
            }
        }
        .navigationTitle("Песни")
        .refreshable { await store.refresh() }
    }

    private func albumHeader(_ group: AlbumGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.album)
            if let artist = group.artist {
                Text(artist)
                    .font(.caption2)
            }
        }
        // На весь заголовок: List капитализирует заголовки секций,
        // названия альбомов и артистов должны остаться как в тегах.
        .textCase(nil)
    }

    private func trackRow(_ track: Track) -> some View {
        let isCurrent = engine.isCurrent(track)
        return HStack(spacing: 8) {
            if isCurrent {
                NowPlayingIndicator(isPlaying: engine.state == .playing)
            }
            Text(track.title)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer()
            TrackCloudBadge(track: track)
            TrackFormatBadge(track: track)
        }
    }
}
