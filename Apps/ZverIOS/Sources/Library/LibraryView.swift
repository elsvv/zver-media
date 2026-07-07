import SwiftUI
import ZverCore

/// Корневой экран «Библиотека» (как в Apple Music): разделы
/// Плейлисты, Артисты, Альбомы, Песни, ниже — грид «Недавно добавленные».
/// Здесь же — первичная загрузка библиотеки и pull-to-refresh.
struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    private static let gridColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    /// Сколько плиток «Недавно добавленных» на корневом экране
    /// (полный список — по «Показать все»).
    private static let recentLimit = 12

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PlaylistsView(store: store, engine: engine)
                } label: {
                    Label("Плейлисты", systemImage: "music.note.list")
                }
                NavigationLink {
                    ArtistsView(store: store, engine: engine)
                } label: {
                    Label("Артисты", systemImage: "music.mic")
                }
                NavigationLink {
                    AlbumsGridView(title: "Альбомы", albums: store.albums,
                                   store: store, engine: engine)
                } label: {
                    Label("Альбомы", systemImage: "square.stack")
                }
                NavigationLink {
                    SongsView(store: store, engine: engine)
                } label: {
                    Label("Песни", systemImage: "music.note")
                }
                NavigationLink {
                    FavoritesView(store: store, engine: engine)
                } label: {
                    Label("Избранное", systemImage: "heart")
                }
            }

            if !recentAlbums.isEmpty {
                Section {
                    // Грид живёт одним рядом списка на прозрачном фоне: сверху —
                    // нативные ряды категорий, ниже — плитки как в «Альбомах».
                    LazyVGrid(columns: Self.gridColumns, spacing: 20) {
                        ForEach(recentAlbums.prefix(Self.recentLimit)) { group in
                            NavigationLink {
                                AlbumDetailView(group: group, store: store, engine: engine)
                            } label: {
                                AlbumTile(group: group, loader: engine.artworkLoader)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Недавно добавленные")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        NavigationLink {
                            AlbumsGridView(title: "Недавно добавленные",
                                           albums: recentAlbums,
                                           store: store, engine: engine)
                        } label: {
                            Text("Показать все")
                                .font(.subheadline)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Библиотека")
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }

    /// Альбомы по свежести добавления: recency папки = максимальный `addedAt`
    /// её треков (доимпорт трека «поднимает» альбом). Треки без даты — защитный
    /// фоллбэк в конец (addedAt заполняется каталогом с v1, пусто не бывает).
    private var recentAlbums: [AlbumGroup] {
        store.albums
            .map { (group: $0, added: $0.tracks.compactMap(\.addedAt).max() ?? .distantPast) }
            .sorted { $0.added > $1.added }
            .map(\.group)
    }
}
