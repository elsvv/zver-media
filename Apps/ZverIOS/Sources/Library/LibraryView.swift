import SwiftUI
import ZverCore

/// Корневой экран «Библиотека» (как в Apple Music): разделы
/// Плейлисты, Артисты, Альбомы, Песни.
/// Здесь же — первичная загрузка библиотеки и pull-to-refresh.
struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        List {
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
        }
        .navigationTitle("Библиотека")
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }
}
