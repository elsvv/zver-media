import SwiftUI
import ZverImport

/// Источник «Internet Archive» (Live Music Archive): нативный поиск легальных концертов
/// во FLAC (включая 24-bit) и загрузка в библиотеку. Поиск → карточки (title, creator,
/// year, downloads) → экран релиза со списком FLAC и кнопкой «Скачать альбом».
///
/// `ArchiveDownloadCenter` приходит сверху (из `ImportHomeView`, `@StateObject` уровня
/// стека «Импорта») — плашка прогресса видна и в селекторе источников, и здесь, и
/// переживает уход с экрана релиза назад.
struct ArchiveImportView: View {
    @ObservedObject var center: ArchiveDownloadCenter
    @StateObject private var model = ArchiveSearchModel()

    var body: some View {
        List {
            ForEach(model.results) { item in
                NavigationLink {
                    ArchiveReleaseView(item: item, center: center)
                } label: {
                    ArchiveResultRow(item: item)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Артист или название концерта")
        .onSubmit(of: .search) { model.search() }
        .navigationTitle("Internet Archive")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { statusOverlay }
        .safeAreaInset(edge: .bottom) {
            ArchiveDownloadsPlate(center: center)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView {
                Label("Live Music Archive", systemImage: "waveform")
            } description: {
                Text("Легальные концерты во FLAC. Введите артиста или название и нажмите «Поиск».")
            }
        case .loading:
            ProgressView()
        case .loaded where model.results.isEmpty:
            ContentUnavailableView.search(text: model.query)
        case let .failed(message):
            ContentUnavailableView {
                Label("Поиск не удался", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Повторить") { model.search() }
            }
        case .loaded:
            EmptyView()
        }
    }
}

/// Строка результата поиска: заголовок концерта, исполнитель·год, число скачиваний.
struct ArchiveResultRow: View {
    let item: ArchiveSearchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title ?? item.identifier)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let downloads = item.downloads {
                    Label(ArchiveFormat.downloads(downloads), systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// «Исполнитель · Год» — то, что есть.
    private var subtitle: String? {
        [item.creator, item.year].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

/// Экран релиза: метаданные концерта, список FLAC-файлов и кнопка «Скачать альбом».
struct ArchiveReleaseView: View {
    let item: ArchiveSearchItem
    @ObservedObject var center: ArchiveDownloadCenter

    @State private var release: ArchiveRelease?
    @State private var phase: LoadPhase = .loading

    enum LoadPhase: Equatable { case loading, loaded, failed }

    var body: some View {
        List {
            if let release {
                Section {
                    header(release)
                }
                Section {
                    if release.flacFiles.isEmpty {
                        Text("В этом концерте нет FLAC-файлов.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(release.flacFiles) { file in
                            fileRow(file)
                        }
                    }
                } header: {
                    Text(release.flacFiles.isEmpty ? "FLAC" : "FLAC · \(release.flacFiles.count)")
                }
            }
        }
        .navigationTitle(item.title ?? item.identifier)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { loadOverlay }
        .safeAreaInset(edge: .bottom) { downloadBar }
        .task { await load() }
    }

    private func header(_ release: ArchiveRelease) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let creator = release.creator {
                Text(creator).font(.headline)
            }
            if let year = release.year {
                Text(year).font(.subheadline).foregroundStyle(.secondary)
            }
            if let downloads = item.downloads {
                Label("\(ArchiveFormat.downloads(downloads)) скачиваний", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fileRow(_ file: ArchiveFile) -> some View {
        HStack(spacing: 10) {
            if let track = file.track {
                Text("\(track)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(file.title ?? file.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if file.format.lowercased().contains("24bit") {
                        Text("24-bit").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                    }
                    if let duration = file.durationSeconds {
                        Text(ArchiveFormat.duration(duration)).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let size = file.sizeBytes {
                        Text(ArchiveFormat.size(size)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var loadOverlay: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed:
            ContentUnavailableView {
                Label("Не удалось открыть релиз", systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Повторить") { Task { await load() } }
            }
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var downloadBar: some View {
        if let release, !release.flacFiles.isEmpty {
            // Пока центр ведёт этот релиз — кнопка неактивна: иначе повторный тап (или
            // возврат в список и повторный вход) поставил бы дубль на ту же загрузку.
            let active = center.isActive(release.identifier)
            Button {
                let title = item.title ?? release.title ?? release.identifier
                center.enqueue(release, title: title)
            } label: {
                Label(active ? "Загружается…" : "Скачать альбом (\(release.flacFiles.count))",
                      systemImage: active ? "arrow.down.circle" : "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(active)
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    private func load() async {
        phase = .loading
        do {
            release = try await ArchiveOrgClient.fetchRelease(identifier: item.identifier)
            phase = .loaded
        } catch {
            phase = .failed
        }
    }
}

/// Плашка прогресса загрузок Internet Archive: строки с долей/статусом. Пустая (скрыта),
/// пока загрузок нет. Общая для экрана IA и селектора источников (`ImportHomeView`).
struct ArchiveDownloadsPlate: View {
    @ObservedObject var center: ArchiveDownloadCenter

    var body: some View {
        if !center.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(center.items) { item in
                    row(item)
                }
                if center.hasActive {
                    Label("Не закрывайте приложение — загрузка прервётся.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func row(_ item: ArchiveDownloadCenter.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                icon(for: item.state)
                Text(item.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(statusText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch item.state {
            case .downloading:
                ProgressView(value: item.fraction)
                Text(item.detail).font(.caption2).foregroundStyle(.secondary)
            case .importing:
                ProgressView().progressViewStyle(.linear)
            case .done, .failed:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func icon(for state: ArchiveDownloadCenter.Item.State) -> some View {
        switch state {
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        case .importing:   Image(systemName: "tray.and.arrow.down").foregroundStyle(.tint)
        case .done:        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func statusText(_ item: ArchiveDownloadCenter.Item) -> String {
        switch item.state {
        case .downloading: return "\(Int(item.fraction * 100))%"
        case .importing:   return "Импорт…"
        case .done:        return "Готово"
        case let .failed(message): return message
        }
    }
}

/// Состояние поиска IA для SwiftUI. Держит строку запроса, результаты и фазу; сам поиск
/// (сеть + разбор) — в `ArchiveOrgClient` из `ZverImport`, здесь только мост в UI.
@MainActor
final class ArchiveSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [ArchiveSearchItem] = []
    @Published private(set) var phase: Phase = .idle

    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    private var task: Task<Void, Never>?

    /// Запускает поиск по текущей строке. Пустая строка сбрасывает результаты. Повторный
    /// вызов отменяет предыдущий запрос.
    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        task?.cancel()
        guard !q.isEmpty else {
            results = []
            phase = .idle
            return
        }
        phase = .loading
        task = Task { [weak self] in
            do {
                let items = try await ArchiveOrgClient.search(query: q)
                guard !Task.isCancelled else { return }
                self?.results = items
                self?.phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed("Проверьте соединение и попробуйте снова.")
            }
        }
    }
}

/// Форматирование чисел релиза для UI (размер, длительность, скачивания).
enum ArchiveFormat {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    static func downloads(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
