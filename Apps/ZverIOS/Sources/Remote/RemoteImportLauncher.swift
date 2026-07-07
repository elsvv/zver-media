import Combine
import Foundation
import ZverTransport

/// Headless-импорт с Мака по команде пульта (`startImport`): тот же стек, что
/// у экрана «Импорт» (Bonjour → сохранённый токен → манифест →
/// `ImportCoordinator`), но без UI-конфирма — Мак уже спарен и авторизован в
/// канале пульта, доверие установлено.
///
/// Публикует агрегированный `RemoteImportStatus` — `RemoteControlService`
/// пушит его Маку (прогресс синка виден на Маке, как на телефоне).
///
/// Выбор Мака: канал пульта не несёт идентичности синк-сервиса, поэтому берём
/// ЕДИНСТВЕННЫЙ видимый в сети спаренный (с сохранённым токеном) синк-Мак;
/// несколько — первый по имени (детерминированно; типичный сетап — один Мак).
@MainActor
final class RemoteImportLauncher: ObservableObject {
    @Published private(set) var status = RemoteImportStatus(
        phase: .idle, albumTitle: nil, completedAlbums: 0, totalAlbums: 0,
        fraction: 0, message: nil)

    private let browserFactory: @Sendable () -> ServiceBrowser
    private let keyStore: KeyStore
    private let clientFactory: @Sendable (String) -> MacSyncClient
    private let downloaderFactory: @Sendable (String) -> RangeDownloading
    private let libraryRoot: URL
    private let stagingRoot: URL
    private let rescan: @MainActor () async -> Void

    private var coordinator: ImportCoordinator?
    private var cancellables: Set<AnyCancellable> = []
    private var isStarting = false

    init(browserFactory: @escaping @Sendable () -> ServiceBrowser = { NWServiceBrowser() },
         keyStore: KeyStore = KeychainKeyStore(),
         clientFactory: @escaping @Sendable (String) -> MacSyncClient = { MacSyncClient(serviceName: $0) },
         downloaderFactory: @escaping @Sendable (String) -> RangeDownloading = { NWFileDownloader(serviceName: $0) },
         libraryRoot: URL = URL.documentsDirectory.appendingPathComponent("Library", isDirectory: true),
         stagingRoot: URL = URL.cachesDirectory.appendingPathComponent("ZverImport", isDirectory: true),
         rescan: @escaping @MainActor () async -> Void = {}) {
        self.browserFactory = browserFactory
        self.keyStore = keyStore
        self.clientFactory = clientFactory
        self.downloaderFactory = downloaderFactory
        self.libraryRoot = libraryRoot
        self.stagingRoot = stagingRoot
        self.rescan = rescan
    }

    /// Запуск по команде пульта. Уже идущий импорт/запуск — no-op (Мак получит
    /// пуш текущего статуса, потому что статус и так публикуется).
    func start() {
        guard !isStarting, !isImportRunning else { return }
        isStarting = true
        status = RemoteImportStatus(phase: .downloading, albumTitle: nil,
                                    completedAlbums: 0, totalAlbums: 0,
                                    fraction: 0, message: "Ищу Мак в сети…")
        Task { @MainActor in
            defer { isStarting = false }
            await run()
        }
    }

    private var isImportRunning: Bool {
        coordinator?.phase == .running
    }

    private func run() async {
        // 1. Найти спаренный синк-Мак (короткий browse, ~3с накопления).
        guard let mac = await discoverPairedMac() else {
            fail("Не вижу спаренный Мак с открытой очередью синка в сети.")
            return
        }
        guard let token = keyStore.token(forService: mac.name) else {
            fail("Для Мака «\(mac.name)» нет сохранённого токена синка.")
            return
        }

        // 2. Манифест.
        let manifest: SyncManifest
        do {
            manifest = try await clientFactory(mac.name).fetchManifest(token: token)
        } catch {
            fail("Не удалось получить очередь Мака: \(Self.message(for: error))")
            return
        }
        guard !manifest.albums.isEmpty else {
            status = RemoteImportStatus(phase: .done, albumTitle: nil,
                                        completedAlbums: 0, totalAlbums: 0,
                                        fraction: 1, message: "Очередь Мака пуста.")
            return
        }

        // 3. Координатор — как MacImportModel.startImport, но без UI.
        let serviceName = mac.name
        let engine = DownloadEngine(libraryRoot: libraryRoot,
                                    stagingRoot: stagingRoot,
                                    downloader: downloaderFactory(serviceName),
                                    token: token)
        let clientFactory = self.clientFactory
        let confirm: @Sendable (String) async throws -> Void = { albumId in
            try await clientFactory(serviceName).confirm(albumId: albumId, token: token)
        }
        let localShas: @Sendable () async -> [String: String] = {
            await Task.detached(priority: .userInitiated) {
                ImportCoordinator.computeLocalShas(manifest: manifest, engine: engine)
            }.value
        }
        let coordinator = ImportCoordinator(manifest: manifest, engine: engine,
                                            confirm: confirm, rescan: rescan,
                                            localShas: localShas)
        self.coordinator = coordinator
        observe(coordinator)
        await coordinator.start()
    }

    /// Один короткий browse: копим сервисы 3 секунды, берём sync-роль со
    /// спаренным токеном (несколько — первый по имени).
    private func discoverPairedMac() async -> DiscoveredService? {
        let browser = browserFactory()
        let holder = ServicesHolder()
        browser.start { services in
            Task { await holder.update(services) }
        }
        try? await Task.sleep(for: .seconds(3))
        browser.stop()
        let services = await holder.current
        let keyStore = self.keyStore
        return services
            .filter { $0.role == ServiceTXT.sync && keyStore.token(forService: $0.name) != nil }
            .sorted { $0.name < $1.name }
            .first
    }

    /// Потокобезопасное накопление последнего снимка сервисов из
    /// @Sendable-колбэка браузера.
    private actor ServicesHolder {
        private(set) var current: [DiscoveredService] = []
        func update(_ services: [DiscoveredService]) { current = services }
    }

    /// Combine-мост: состояние координатора → агрегированный RemoteImportStatus.
    private func observe(_ coordinator: ImportCoordinator) {
        cancellables.removeAll()
        coordinator.$albums.combineLatest(coordinator.$phase)
            .sink { [weak self] albums, phase in
                self?.status = Self.aggregate(albums: albums, phase: phase)
            }
            .store(in: &cancellables)
    }

    /// Свод по альбомам: доля = среднее по альбомам (done=1, downloading=его
    /// прогресс, finalizing≈0.95), текущий заголовок — первый качающийся.
    private static func aggregate(albums: [ImportCoordinator.AlbumImport],
                                  phase: ImportCoordinator.Phase) -> RemoteImportStatus {
        let total = albums.count
        var completed = 0
        var fractionSum = 0.0
        var currentTitle: String?
        var failureMessage: String?
        for album in albums {
            switch album.phase {
            case .waiting:
                break
            case let .downloading(progress):
                fractionSum += progress
                if currentTitle == nil { currentTitle = album.title }
            case .finalizing:
                fractionSum += 0.95
                if currentTitle == nil { currentTitle = album.title }
            case .done:
                completed += 1
                fractionSum += 1
            case let .failed(message):
                if failureMessage == nil { failureMessage = message }
            }
        }
        let remotePhase: RemoteImportStatus.Phase
        var message: String?
        switch phase {
        case .idle: remotePhase = .idle
        case .running: remotePhase = .downloading
        case .finished:
            remotePhase = failureMessage == nil ? .done : .failed
            message = failureMessage
        case let .failed(text):
            remotePhase = .failed
            message = text
        }
        return RemoteImportStatus(
            phase: remotePhase,
            albumTitle: currentTitle,
            completedAlbums: completed,
            totalAlbums: total,
            fraction: total > 0 ? min(fractionSum / Double(total), 1) : 0,
            message: message)
    }

    private func fail(_ text: String) {
        status = RemoteImportStatus(phase: .failed, albumTitle: nil,
                                    completedAlbums: 0, totalAlbums: 0,
                                    fraction: 0, message: text)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case MacSyncClient.ClientError.timeout: return "Мак не ответил вовремя."
        case let MacSyncClient.ClientError.httpStatus(code): return "HTTP \(code)."
        case MacSyncClient.ClientError.connectionFailed: return "нет соединения."
        default: return "неизвестная ошибка."
        }
    }
}
