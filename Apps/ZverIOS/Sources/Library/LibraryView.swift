import SwiftUI
import ZverCore

/// Корневой экран «Библиотека» (как в Apple Music): разделы
/// Плейлисты (заглушка до S2-9), Артисты, Альбомы, Песни.
/// Здесь же — первичная загрузка библиотеки и pull-to-refresh.
struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        List {
            // Плейлисты: экран появится в S2-9, пока неактивный ряд.
            Label("Плейлисты", systemImage: "music.note.list")
                .foregroundStyle(.secondary)
            NavigationLink {
                ArtistsView(store: store, engine: engine)
            } label: {
                Label("Артисты", systemImage: "music.mic")
            }
            NavigationLink {
                AlbumsGridView(title: "Альбомы", albums: store.albums, engine: engine)
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
