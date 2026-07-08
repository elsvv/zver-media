import Foundation
import WebKit
import ZverImport

/// Владелец скачиваний из webview-источников (Bandcamp). Живёт на уровне вью-стека
/// «Импорта» (`@StateObject` в `ImportHomeView`), а не в самой вкладке webview —
/// поэтому плашка прогресса видна из селектора источников и переживает уход с экрана
/// Bandcamp назад в список. Держит сильные ссылки на `WKDownload` (их делегат —
/// `weak`), KVO-наблюдение прогресса и папку назначения для каждого скачивания.
///
/// По завершении файл (из tmp) уходит в `AlbumImporter` тем же путём, что и «Из
/// файлов» (`importPicked`: zip → архив, иначе — россыпь), затем рескан библиотеки и
/// баннер-итог поверх табов.
///
/// Ограничение MVP: `WKDownload` умирает вместе с процессом — при уходе из
/// приложения докачки нет (предупреждаем в UI). v2: отменять и переигрывать
/// `originalRequest` через background `URLSession`.
@MainActor
final class WebDownloadCenter: NSObject, ObservableObject, WKDownloadDelegate {
    /// Состояние одного скачивания для UI.
    struct Item: Identifiable {
        let id: ObjectIdentifier
        var filename: String
        var fraction: Double
        var state: State

        enum State: Equatable {
            case downloading
            case importing
            case done(String)
            case failed(String)
        }
    }

    /// Активные и недавно завершённые скачивания (в порядке появления).
    @Published private(set) var items: [Item] = []

    /// Рескан библиотеки + автобэкап (тот же, что у «С Мака»/«Из файлов»).
    private let rescan: @MainActor () async -> Void
    /// Плашка-итог поверх табов (владелец — `ContentView`).
    private let showBanner: @MainActor (String) -> Void
    /// Корень библиотеки — `Documents/Library`.
    private let libraryRoot: URL

    /// Сильные ссылки на активные скачивания (их делегат — `weak`, иначе `WKDownload`
    /// освободится при уходе с экрана webview и загрузка оборвётся).
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    /// KVO-наблюдение `progress.fractionCompleted` по каждому скачиванию.
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    /// Файл назначения (в своей tmp-папке) по каждому скачиванию — источник импорта.
    private var destinations: [ObjectIdentifier: URL] = [:]

    init(
        rescan: @escaping @MainActor () async -> Void,
        showBanner: @escaping @MainActor (String) -> Void,
        libraryRoot: URL = URL.documentsDirectory.appendingPathComponent("Library", isDirectory: true)
    ) {
        self.rescan = rescan
        self.showBanner = showBanner
        self.libraryRoot = libraryRoot
        super.init()
    }

    /// Есть ли активные (качающиеся/импортируемые) скачивания — для предупреждения в UI.
    var hasActive: Bool {
        items.contains { $0.state == .downloading || $0.state == .importing }
    }

    // MARK: - Регистрация (из координатора webview)

    /// Принимает новое скачивание, перехваченное навигационным делегатом webview.
    /// Становится его делегатом (после этого WebKit спросит папку назначения),
    /// заводит строку прогресса и подписывается на `progress`.
    func register(_ download: WKDownload) {
        let oid = ObjectIdentifier(download)
        downloads[oid] = download
        items.append(Item(id: oid, filename: "Загрузка…", fraction: 0, state: .downloading))
        download.delegate = self

        // Прогресс из `download.progress` (NSProgressReporting). KVO может прийти с
        // произвольного потока — переносим только Sendable-долю на MainActor.
        observations[oid] = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in self?.setFraction(oid, fraction) }
        }
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let oid = ObjectIdentifier(download)
        let name = WebDownloadPolicy.sanitizedFilename(suggestedFilename)
        // Своя tmp-папка на каждое скачивание: назначение должно НЕ существовать в
        // существующей папке (требование WKDownload), а имена разных релизов не должны
        // сталкиваться.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bandcamp-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            fail(oid, message: "Не удалось подготовить папку загрузки.")
            return
        }
        let dest = dir.appendingPathComponent(name)
        destinations[oid] = dest
        setFilename(oid, name)
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let oid = ObjectIdentifier(download)
        observations[oid]?.invalidate()
        observations[oid] = nil
        guard let fileURL = destinations[oid] else {
            fail(oid, message: "Файл загрузки не найден.")
            return
        }
        let dir = fileURL.deletingLastPathComponent()
        setState(oid, .importing)
        setFraction(oid, 1)

        let importer = AlbumImporter(libraryRoot: libraryRoot)
        Task { [weak self] in
            let text: String
            let ok: Bool
            do {
                // Тот же путь, что «Из файлов»: zip → архив, иначе — россыпь из одного
                // файла. Источник (файл в tmp) importPicked удаляет по успеху.
                let results = try await importer.importPicked([fileURL])
                await self?.rescan()
                text = ImportHomeView.bannerText(for: results)
                ok = true
            } catch {
                text = "Импорт не удался"
                ok = false
            }
            try? FileManager.default.removeItem(at: dir)
            guard let self else { return }
            if ok {
                self.showBanner(text)
                self.finish(oid, state: .done(text))
            } else {
                self.finish(oid, state: .failed("Импорт не удался"))
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let oid = ObjectIdentifier(download)
        if let dest = destinations[oid] {
            try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
        }
        fail(oid, message: "Загрузка прервалась.")
    }

    // MARK: - Обновление состояния

    private func setFraction(_ oid: ObjectIdentifier, _ fraction: Double) {
        guard let idx = items.firstIndex(where: { $0.id == oid }) else { return }
        // После импорта/ошибки долю не двигаем.
        if case .downloading = items[idx].state {
            items[idx].fraction = fraction
        }
    }

    private func setFilename(_ oid: ObjectIdentifier, _ name: String) {
        guard let idx = items.firstIndex(where: { $0.id == oid }) else { return }
        items[idx].filename = name
    }

    private func setState(_ oid: ObjectIdentifier, _ state: Item.State) {
        guard let idx = items.firstIndex(where: { $0.id == oid }) else { return }
        items[idx].state = state
    }

    private func fail(_ oid: ObjectIdentifier, message: String) {
        observations[oid]?.invalidate()
        observations[oid] = nil
        finish(oid, state: .failed(message))
    }

    /// Помечает скачивание завершённым, освобождает его ресурсы и гасит строку через
    /// несколько секунд (успех уже показан баннером; ошибка задерживается дольше).
    private func finish(_ oid: ObjectIdentifier, state: Item.State) {
        setState(oid, state)
        downloads[oid] = nil
        observations[oid]?.invalidate()
        observations[oid] = nil
        destinations[oid] = nil
        let delay: Duration = {
            if case .failed = state { return .seconds(8) }
            return .seconds(3)
        }()
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.items.removeAll { $0.id == oid }
        }
    }
}
