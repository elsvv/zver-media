import SwiftUI
import ZverCore

struct ContentView: View {
    @StateObject private var engine = PlayerEngine()
    // Автобэкап новых альбомов — тумблер из Настроек (тот же ключ @AppStorage).
    @AppStorage(SettingsView.autoBackupKey) private var autoBackupNewAlbums = true
    // Аккаунт облака (Яндекс.Диск): токен в Keychain, статус для Настроек (этап 4).
    @StateObject private var account: CloudAccount
    // Каталог один: треки и плейлисты живут в одной БД (FK-связи). Сервис бэкапа
    // строится на том же CatalogStore — отсюда (а не из LibraryStore.openCatalog),
    // чтобы CatalogStore был общим у библиотеки и бэкапа.
    @StateObject private var library: LibraryStore
    // Сервис облачного бэкапа (этап 4): очередь поверх YandexDiskStore, переходы
    // fileState, авто-/ручная выгрузка и скачивание.
    @StateObject private var backup: BackupService

    init() {
        let catalog = LibraryStore.openCatalog()
        let catalogStore = CatalogStore(catalog: catalog)
        let account = CloudAccount()
        _account = StateObject(wrappedValue: account)
        let library = LibraryStore(
            catalogStore: catalogStore,
            playlistStore: PlaylistStore(catalog: catalog)
        )
        let backup = BackupService(
            catalogStore: catalogStore,
            tokenProvider: account.tokenProvider
        )
        // Обёртки облака в UI идут через LibraryStore (UI не знает про BackupService
        // напрямую). Связь — слабая (оба живут весь сеанс как @StateObject).
        library.backupService = backup
        _library = StateObject(wrappedValue: library)
        _backup = StateObject(wrappedValue: backup)
    }

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
                // правки из sidecar и добавит новые треки в библиотеку. Затем —
                // автобэкап новых local-треков в облако (если залогинены).
                MacImportView(rescan: {
                    await library.refresh()
                    if account.isAuthorized, autoBackupNewAlbums {
                        await backup.backupAwaitingTracks()
                    }
                })
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Импорт", systemImage: "laptopcomputer.and.arrow.down") }

            NavigationStack {
                SettingsView(account: account, store: library, backup: backup)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Облако", systemImage: "icloud") }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if engine.queue.current != nil {
            MiniPlayerBar(engine: engine)
        }
    }
}
