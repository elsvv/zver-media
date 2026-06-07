import SwiftUI
import ZverCore

struct ContentView: View {
    @StateObject private var engine = PlayerEngine()
    @StateObject private var library = LibraryStore(
        catalogStore: CatalogStore(catalog: LibraryStore.openCatalog())
    )

    var body: some View {
        NavigationStack {
            LibraryView(store: library, engine: engine)
        }
        // Мини-плеер поверх всех экранов навигации: inset применяется
        // ко всему стеку, контент списков не прячется под баром.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if engine.queue.current != nil {
                MiniPlayerBar(engine: engine)
            }
        }
    }
}
