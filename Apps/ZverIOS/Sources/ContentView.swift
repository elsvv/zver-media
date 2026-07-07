import SwiftUI
import ZverCore
import ZverImport

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
    // «ИИ» (LLM-рекомендации): профили провайдеров (тип API/ключ/модель/tools)
    // в настройках; лента генерируется вручную и кэшируется на диске.
    @StateObject private var brain: BrainProfilesStore
    @StateObject private var homeFeed: HomeFeedService

    /// Плашка-баннер после системного «Открыть в Zver Media» (импорт из
    /// Safari/Files/AirDrop). nil — баннера нет. Гаснет сам через несколько секунд
    /// или по тапу.
    @State private var importBanner: String?
    /// Автогашение баннера; пересоздаётся при новом импорте (сбрасывает таймер).
    @State private var bannerDismiss: Task<Void, Never>?

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
        let brain = BrainProfilesStore()
        _brain = StateObject(wrappedValue: brain)
        _homeFeed = StateObject(wrappedValue: HomeFeedService(library: library, profiles: brain))
    }

    var body: some View {
        TabView {
            NavigationStack {
                HomeView(store: library, engine: engine,
                         feedService: homeFeed, profiles: brain)
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
                // Селектор источников импорта (Мак / Bandcamp / IA / Из файлов).
                // rescan — reconcile каталога после раскладки альбома (правки из
                // sidecar + новые треки) с последующим автобэкапом; раздаётся
                // источникам. showBanner — общая плашка-итог поверх табов.
                ImportHomeView(rescan: { await refreshAndBackup() },
                               showBanner: { text in showBanner(text) })
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Импорт", systemImage: "square.and.arrow.down") }

            NavigationStack {
                SettingsView(account: account, store: library, backup: backup,
                             remote: remote, player: engine, brain: brain)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .tabItem { Label("Настройки", systemImage: "gearshape") }
        }
        // Системное «Открыть в Zver Media»: файл из Safari/Files/AirDrop/почты →
        // staging-копия → AlbumImporter → баннер → рескан библиотеки.
        .onOpenURL { url in Task { await handleOpenURL(url) } }
        .overlay(alignment: .top) { bannerOverlay }
        .animation(.spring(duration: 0.35), value: importBanner)
    }

    // MARK: - «Открыть в Zver Media»

    /// Импортирует открытый системой файл и показывает результат баннером.
    @MainActor
    private func handleOpenURL(_ url: URL) async {
        let libraryRoot = URL.documentsDirectory
            .appendingPathComponent("Library", isDirectory: true)
        do {
            let results = try await OpenInImporter.importOpened(url, libraryRoot: libraryRoot)
            await refreshAndBackup()
            showBanner(ImportHomeView.bannerText(for: results))
        } catch {
            showBanner("Импорт не удался")
        }
    }

    /// Рескан библиотеки + автобэкап новых local-треков (если залогинены и включён
    /// тумблер). Общий пост-импортный путь для «С Мака» и «Открыть в Zver».
    @MainActor
    private func refreshAndBackup() async {
        await library.refresh()
        if account.isAuthorized, autoBackupNewAlbums {
            await backup.backupAwaitingTracks()
        }
    }

    @MainActor
    private func showBanner(_ text: String) {
        importBanner = text
        bannerDismiss?.cancel()
        bannerDismiss = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            importBanner = nil
        }
    }

    @ViewBuilder
    private var bannerOverlay: some View {
        if let importBanner {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(importBanner)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.horizontal)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { self.importBanner = nil }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if engine.queue.current != nil {
            MiniPlayerBar(engine: engine)
        }
    }
}
