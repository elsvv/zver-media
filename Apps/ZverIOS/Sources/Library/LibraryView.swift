import SwiftUI
import ZverCore

/// Библиотека: список треков с секциями по альбомам,
/// тап по треку запускает воспроизведение альбома с него.
struct LibraryView: View {
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
        .navigationTitle("Zver")
        .task { await store.refresh() }
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
            Text(formatBadge(for: track))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
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
}
