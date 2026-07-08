import SwiftUI
import ZverCore

/// Раздел «Избранное»: сверху грид любимых альбомов, ниже — список любимых
/// песен (тап — очередь из избранных песен с этой позиции). Пустое избранное —
/// подсказка, как добавлять.
struct FavoritesView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    private static let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        List {
            if !store.favoriteAlbums.isEmpty {
                Section {
                    LazyVGrid(columns: Self.gridColumns, spacing: 20) {
                        ForEach(store.favoriteAlbums) { group in
                            // Value-based навигация: closure-`NavigationLink` внутри
                            // `LazyVGrid` в `List`-строке открывал НЕ ТОТ альбом и ломал
                            // стек. `NavigationLink(value:)` + `navigationDestination`
                            // резолвят пункт назначения стеком по значению — баг уходит.
                            NavigationLink(value: group) {
                                AlbumTile(group: group, loader: engine.artworkLoader)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Альбомы").font(.title3.weight(.semibold)).textCase(nil)
                }
            }

            if !store.favoriteTracks.isEmpty {
                Section {
                    ForEach(Array(store.favoriteTracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            if track.fileState == .remote {
                                Task { await store.download(track: track) }
                            } else {
                                engine.play(tracks: store.favoriteTracks, startAt: index)
                            }
                        } label: {
                            trackRow(track)
                        }
                        .addToPlaylistMenu(for: track, store: store)
                        .cloudActions(for: track, store: store)
                    }
                } header: {
                    Text("Песни").font(.title3.weight(.semibold)).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Избранное")
        .navigationDestination(for: AlbumGroup.self) { group in
            AlbumDetailView(group: group, store: store, engine: engine)
        }
        .overlay {
            if store.favoriteAlbums.isEmpty && store.favoriteTracks.isEmpty {
                ContentUnavailableView(
                    "Пока пусто",
                    systemImage: "heart",
                    description: Text("Добавляйте альбомы и треки в избранное " +
                                      "через сердечко на экране альбома и в меню трека.")
                )
            }
        }
    }

    private func trackRow(_ track: Track) -> some View {
        let isCurrent = engine.isCurrent(track)
        return HStack(spacing: 8) {
            if isCurrent {
                NowPlayingIndicator(isPlaying: engine.state == .playing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            TrackCloudBadge(track: track)
            TrackFormatBadge(track: track)
        }
    }
}
