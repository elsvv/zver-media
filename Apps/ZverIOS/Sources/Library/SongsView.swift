import SwiftUI
import ZverCore

/// Раздел «Песни»: список треков секциями по альбомам,
/// тап по треку запускает воспроизведение альбома с него.
struct SongsView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        List(store.albums, id: \.album) { group in
            Section {
                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        engine.play(tracks: group.tracks, startAt: index)
                    } label: {
                        trackRow(track)
                    }
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
                    .textCase(nil)
            }
        }
    }

    private func trackRow(_ track: Track) -> some View {
        HStack {
            Text(track.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            TrackFormatBadge(track: track)
        }
    }
}
