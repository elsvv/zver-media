import SwiftUI
import ZverCore

struct ContentView: View {
    @StateObject private var engine = PlayerEngine()
    @StateObject private var library = LibraryStore(
        catalogStore: CatalogStore(catalog: LibraryStore.openCatalog())
    )

    var body: some View {
        NavigationStack {
            ZStack {
                LibraryView(store: library, engine: engine)
                VStack {
                    Spacer()
                    if engine.queue.current != nil {
                        MiniPlayerBar(engine: engine)
                    }
                }
            }
        }
    }
}
