import SwiftUI
import ZverCore

struct ContentView: View {
    @StateObject private var engine: PlayerEngine
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
    // Пульт с Мака (этап 5): WS-сервер + pairing-хост + приём команд. Строится на
    // тех же engine/library; UI (тумблер/код/режим паузы) добавит S5-6.
    @StateObject private var remote: RemoteControlService
    // «Интеллект» (LLM-рекомендации, этап «Главная+AI»): ключ/URL/модель в
    // настройках; лента генерируется вручную и кэшируется на диске.
    @StateObject private var brain: BrainAccount
    @StateObject private var homeFeed: HomeFeedService

    init() {
        let catalog = LibraryStore.openCatalog()
        let catalogStore = CatalogStore(catalog: catalog)
        let account = CloudAccount()
        _account = StateObject(wrappedValue: account)
        let library = LibraryStore(
            catalogStore: catalogStore,
            playlistStore: PlaylistStore(catalog: catalog),
            favoriteStore: FavoriteStore(catalog: catalog),
            historyStore: PlayHistoryStore(catalog: catalog)
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
        // Пульт держит слабые ссылки на engine/library — оба живут весь сеанс как
        // @StateObject. Сервер не запускается, пока пользователь не включит тумблер.
        let engine = PlayerEngine()
        // Headless-импорт по команде Мака (этап «Mac-редизайн»): тот же
        // пост-импортный rescan+автобэкап, что у кнопки в MacImportView.
        let importLauncher = RemoteImportLauncher(rescan: { [weak library, weak account, weak backup] in
            await library?.refresh()
            if account?.isAuthorized == true,
               UserDefaults.standard.object(forKey: SettingsView.autoBackupKey) as? Bool ?? true {
                await backup?.backupAwaitingTracks()
            }
        })
        // История прослушивания: движок отдаёт события (что играло, сколько,
        // чем закончилось), LibraryStore превращает их в строки playEvent
        // с переносимыми ключами. Оба живут весь сеанс как @StateObject.
        engine.onTrackPlayed = { [weak library] track, startedAt, played, reason in
            library?.recordPlayEvent(track: track, startedAt: startedAt,
                                     playedSeconds: played, reason: reason)
        }
        _engine = StateObject(wrappedValue: engine)
        let remote = RemoteControlService(player: engine, library: library)
        remote.importLauncher = importLauncher
        _remote = StateObject(wrappedValue: remote)
        let brain = BrainAccount()
        _brain = StateObject(wrappedValue: brain)
        _homeFeed = StateObject(wrappedValue: HomeFeedService(library: library, account: brain))
    }

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(store: library, engine: engine,
                         feedService: homeFeed, account: brain)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Главная", systemImage: "house") }

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
                SettingsView(account: account, store: library, backup: backup,
                             remote: remote, player: engine, brain: brain)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if engine.queue.current != nil {
            MiniPlayerBar(engine: engine)
        }
    }
}
