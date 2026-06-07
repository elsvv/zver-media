import SwiftUI
import ZverCore

struct ContentView: View {
    @StateObject private var engine = PlayerEngine()
    // Каталог один: треки и плейлисты живут в одной БД (FK-связи).
    @StateObject private var library: LibraryStore = {
        let catalog = LibraryStore.openCatalog()
        return LibraryStore(catalogStore: CatalogStore(catalog: catalog),
                            playlistStore: PlaylistStore(catalog: catalog))
    }()

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView(store: library, engine: engine)
            }
            // Мини-плеер поверх всех экранов навигации таба: inset
            // применяется ко всему стеку (контент списков не прячется
            // под баром) и остаётся над таб-баром. На TabView целиком
            // inset нельзя — лёг бы ПОД таб-баром.
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Библиотека", systemImage: "music.note.list") }

            NavigationStack {
                SearchView(store: library, engine: engine)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Поиск", systemImage: "magnifyingglass") }

            NavigationStack {
                // Рескан каталога после импорта альбома: reconcile подхватит
                // правки из sidecar и добавит новые треки в библиотеку.
                MacImportView(rescan: { await library.refresh() })
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Импорт", systemImage: "laptopcomputer.and.arrow.down") }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if engine.queue.current != nil {
            MiniPlayerBar(engine: engine)
        }
    }
}
