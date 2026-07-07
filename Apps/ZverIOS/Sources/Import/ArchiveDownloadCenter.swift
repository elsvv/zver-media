import Foundation
import ZverImport

/// Владелец скачиваний из Internet Archive. Живёт на уровне вью-стека «Импорта»
/// (`@StateObject` в `ImportHomeView`), а не в самой вкладке IA — плашка прогресса
/// видна из селектора источников и переживает уход с экрана релиза назад в список.
///
/// Последовательная очередь: релизы качаются по одному, файлы внутри релиза — тоже по
/// одному (`ArchiveDownloader` с Range-докачкой). Оборвавшийся файл повторяем несколько
/// раз, докачивая с уже скачанной позиции (частичный файл переживает сбой). По успеху
/// весь набор FLAC уходит в `AlbumImporter.importFiles` (россыпь группируется по тегам),
/// затем рескан библиотеки и баннер-итог поверх табов.
@MainActor
final class ArchiveDownloadCenter: ObservableObject {
    /// Состояние одной загрузки релиза для UI.
    struct Item: Identifiable {
        let id: UUID
        var title: String
        /// Доля готовности всего релиза 0...1.
        var fraction: Double
        /// Подпись «Файл N из M» / «В очереди».
        var detail: String
        var state: State

        enum State: Equatable {
            case downloading
            case importing
            case done(String)
            case failed(String)
        }
    }

    /// Активные и недавно завершённые загрузки (в порядке появления).
    @Published private(set) var items: [Item] = []

    /// Рескан библиотеки + автобэкап (тот же, что у «С Мака»/«Из файлов»/Bandcamp).
    private let rescan: @MainActor () async -> Void
    /// Плашка-итог поверх табов (владелец — `ContentView`).
    private let showBanner: @MainActor (String) -> Void
    /// Корень библиотеки — `Documents/Library`.
    private let libraryRoot: URL

    private let downloader = ArchiveDownloader()

    /// Очередь ожидающих релизов (id строки + релиз + человекочитаемый заголовок).
    private var pending: [(id: UUID, release: ArchiveRelease, title: String)] = []
    private var isRunning = false

    /// Сколько раз повторяем оборвавшийся файл (докачивая с Range) до сдачи.
    private let maxAttemptsPerFile = 3

    init(
        rescan: @escaping @MainActor () async -> Void,
        showBanner: @escaping @MainActor (String) -> Void,
        libraryRoot: URL = URL.documentsDirectory.appendingPathComponent("Library", isDirectory: true)
    ) {
        self.rescan = rescan
        self.showBanner = showBanner
        self.libraryRoot = libraryRoot
    }

    /// Есть ли активные (качающиеся/импортируемые) загрузки — для предупреждения в UI.
    var hasActive: Bool {
        items.contains { $0.state == .downloading || $0.state == .importing }
    }

    // MARK: - Постановка в очередь

    /// Ставит релиз в очередь на скачивание. Повторную постановку уже активного релиза
    /// (по identifier) игнорируем, чтобы не плодить дубли загрузок.
    func enqueue(_ release: ArchiveRelease, title: String) {
        guard !release.flacFiles.isEmpty else { return }
        if pending.contains(where: { $0.release.identifier == release.identifier }) { return }

        let id = UUID()
        items.append(Item(id: id, title: title, fraction: 0, detail: "В очереди", state: .downloading))
        pending.append((id: id, release: release, title: title))
        pump()
    }

    // MARK: - Последовательная обработка

    private func pump() {
        guard !isRunning, !pending.isEmpty else { return }
        isRunning = true
        let job = pending.removeFirst()
        Task { [weak self] in
            await self?.run(job)
            guard let self else { return }
            self.isRunning = false
            self.pump()
        }
    }

    private func run(_ job: (id: UUID, release: ArchiveRelease, title: String)) async {
        let release = job.release
        let total = release.flacFiles.count
        // Общий размер (для доли): если у части файлов размер неизвестен — считаем по
        // числу файлов (каждый файл = равная доля).
        let totalBytes = release.flacFiles.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let byBytes = totalBytes > 0 && release.flacFiles.allSatisfy { ($0.sizeBytes ?? 0) > 0 }

        // Своя staging-папка на релиз; подпапка названа по релизу — это фоллбэк имени
        // альбома в `importFiles`, если у FLAC нет тега ALBUM (частый случай на etree).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(job.id.uuidString)", isDirectory: true)
        let folderName = WebDownloadPolicy.sanitizedFilename(job.title, fallback: release.identifier)
        let staging = root.appendingPathComponent(folderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            var staged: [URL] = []
            var doneBytes: Int64 = 0
            var usedNames: Set<String> = []

            for (index, file) in release.flacFiles.enumerated() {
                setDetail(job.id, "Файл \(index + 1) из \(total)")
                let name = uniqueName(from: file.name, used: &usedNames)
                let dest = staging.appendingPathComponent(name)
                let url = ArchiveOrgClient.downloadURL(identifier: release.identifier, fileName: file.name)

                let base = doneBytes
                try await downloadWithRetry(url: url, to: dest, expectedBytes: file.sizeBytes) { [weak self] fileFraction in
                    // Прогресс приходит с сетевой очереди — Sendable-долю на MainActor.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let fraction: Double
                        if byBytes {
                            let fileBytes = Double(file.sizeBytes ?? 0)
                            fraction = min(1.0, (Double(base) + fileFraction * fileBytes) / Double(totalBytes))
                        } else {
                            fraction = min(1.0, (Double(index) + fileFraction) / Double(total))
                        }
                        self.setFraction(job.id, fraction)
                    }
                }
                staged.append(dest)
                doneBytes += file.sizeBytes ?? 0
                setFraction(job.id, byBytes ? min(1.0, Double(doneBytes) / Double(totalBytes))
                                            : min(1.0, Double(index + 1) / Double(total)))
            }

            // Все FLAC на диске — раскладываем как россыпь (группируется по тегам).
            setState(job.id, .importing)
            let importer = AlbumImporter(libraryRoot: libraryRoot)
            let results = try await importer.importFiles(staged)
            await rescan()
            try? FileManager.default.removeItem(at: root)

            let text = ImportHomeView.bannerText(for: results)
            showBanner(text)
            finish(job.id, state: .done(text))
        } catch {
            try? FileManager.default.removeItem(at: root)
            finish(job.id, state: .failed("Загрузка прервалась"))
        }
    }

    /// Качает файл с повтором: оборвавшуюся загрузку переигрываем, докачивая с уже
    /// скачанной позиции (частичный файл на диске переживает попытки). Отмену
    /// (`CancellationError`) пробрасываем сразу — не ретраим.
    private func downloadWithRetry(
        url: URL,
        to dest: URL,
        expectedBytes: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await downloader.download(from: url, to: dest, expectedBytes: expectedBytes, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                if attempt >= maxAttemptsPerFile { throw error }
                // Небольшая пауза перед докачкой — сеть могла флапнуть.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Уникальное плоское имя файла в staging: путь IA (`d1/01 track.flac`) сводим к
    /// базовому имени; коллизии базовых имён разводим индексом-префиксом.
    private func uniqueName(from rawPath: String, used: inout Set<String>) -> String {
        let base = WebDownloadPolicy.sanitizedFilename(rawPath)
        var candidate = base
        var i = 1
        while used.contains(candidate) {
            candidate = "\(i)-\(base)"
            i += 1
        }
        used.insert(candidate)
        return candidate
    }

    // MARK: - Обновление состояния

    private func setFraction(_ id: UUID, _ fraction: Double) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if case .downloading = items[idx].state {
            items[idx].fraction = fraction
        }
    }

    private func setDetail(_ id: UUID, _ detail: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].detail = detail
    }

    private func setState(_ id: UUID, _ state: Item.State) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = state
    }

    /// Помечает загрузку завершённой и гасит строку через несколько секунд (успех уже
    /// показан баннером; ошибка задерживается дольше, чтобы её заметили).
    private func finish(_ id: UUID, state: Item.State) {
        setState(id, state)
        let delay: Duration = {
            if case .failed = state { return .seconds(8) }
            return .seconds(3)
        }()
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.items.removeAll { $0.id == id }
        }
    }
}
