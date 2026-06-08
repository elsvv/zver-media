import SwiftUI
import ZverCore

/// Экран альбома: крупная обложка, название/артист/год, кнопки
/// «Играть»/«Перемешать» и список треков с номерами и бейджами формата.
/// Тап по треку — воспроизведение альбома с него.
struct AlbumDetailView: View {
    let group: AlbumGroup
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        // remote-трек (файла нет) тапом качается, а не играет.
                        if track.fileState == .remote {
                            Task { await store.download(track: track) }
                        } else {
                            engine.play(tracks: group.tracks, startAt: index)
                        }
                    } label: {
                        trackRow(track, fallbackNumber: index + 1)
                    }
                    .addToPlaylistMenu(for: track, store: store)
                    .cloudActions(for: track, store: store)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(group.album)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(spacing: 12) {
            AlbumArtworkView(track: group.tracks.first,
                             loader: engine.artworkLoader,
                             cornerRadius: 10)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            VStack(spacing: 4) {
                Text(group.album)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(group.artist ?? ArtistsView.unknownArtistName)
                    .foregroundStyle(.secondary)
                if let year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 12) {
                Button {
                    engine.play(tracks: group.tracks, startAt: 0)
                } label: {
                    Label("Играть", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    // Перемешивание — простой shuffle массива перед запуском.
                    engine.play(tracks: group.tracks.shuffled(), startAt: 0)
                } label: {
                    Label("Перемешать", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
            }
            // Не .plain/.automatic: в ряду List кнопки с автоматическим стилем
            // срабатывают вместе по тапу в любом месте ряда, .bordered
            // даёт каждой собственную зону нажатия.
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Год альбома — первый непустой тег года среди треков.
    private var year: Int? {
        group.tracks.compactMap(\.year).first
    }

    private func trackRow(_ track: Track, fallbackNumber: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(track.trackNumber ?? fallbackNumber))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            Text(track.title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            TrackCloudBadge(track: track)
            TrackFormatBadge(track: track)
        }
    }
}
