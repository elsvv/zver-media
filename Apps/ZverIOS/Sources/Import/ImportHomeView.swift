import SwiftUI
import UniformTypeIdentifiers
import ZverImport

/// Корень вкладки «Импорт»: селектор источников. Живёт в существующем
/// `NavigationStack` вкладки (см. `ContentView`). Пункты:
/// - «С Мака» — существующий `MacImportView` (Wi-Fi-очередь с Мака);
/// - «Bandcamp» / «Internet Archive» — заглушки до задач 5-6;
/// - «Из файлов» — системный `fileImporter` (zip/аудио) → staging → `AlbumImporter`.
///
/// `rescan` (рескан библиотеки + автобэкап) инъектируется из `ContentView` и
/// раздаётся источникам: сейчас его получают «С Мака» и «Из файлов» (те, что уже
/// умеют импортировать), Bandcamp/IA подключат его при реализации в задачах 5-6.
/// `showBanner` показывает плашку-итог поверх табов — её владелец `ContentView`,
/// тот же баннер, что у системного «Открыть в Zver Media».
struct ImportHomeView: View {
    let rescan: @MainActor () async -> Void
    let showBanner: @MainActor (String) -> Void

    /// Владелец скачиваний webview (Bandcamp): живёт на уровне стека «Импорта», а не
    /// вкладки webview, — плашка прогресса видна отсюда, из селектора, и переживает
    /// уход с экрана Bandcamp назад в список.
    @StateObject private var downloadCenter: WebDownloadCenter

    @State private var isPickingFiles = false
    @State private var isImporting = false

    init(rescan: @escaping @MainActor () async -> Void,
         showBanner: @escaping @MainActor (String) -> Void) {
        self.rescan = rescan
        self.showBanner = showBanner
        _downloadCenter = StateObject(
            wrappedValue: WebDownloadCenter(rescan: rescan, showBanner: showBanner))
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MacImportView(rescan: rescan)
                } label: {
                    sourceRow("С Мака", systemImage: "laptopcomputer.and.arrow.down",
                              subtitle: "Альбомы из очереди на Маке по Wi-Fi")
                }
                NavigationLink {
                    BandcampImportView(center: downloadCenter)
                } label: {
                    sourceRow("Bandcamp", systemImage: "cart",
                              subtitle: "Купленные и бесплатные релизы во FLAC")
                }
                NavigationLink {
                    ArchiveImportView()
                } label: {
                    sourceRow("Internet Archive", systemImage: "waveform",
                              subtitle: "Концерты Live Music Archive во FLAC")
                }
            }

            Section {
                Button {
                    isPickingFiles = true
                } label: {
                    sourceRow("Из файлов", systemImage: "folder",
                              subtitle: "ZIP-архивы и аудио из «Файлов» и iCloud")
                }
                .disabled(isImporting)
            } footer: {
                Text("Выберите ZIP-архив альбома или отдельные аудиофайлы — они разложатся в библиотеку.")
            }
        }
        .navigationTitle("Импорт")
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.zip, .audio],
            allowsMultipleSelection: true
        ) { result in
            handlePick(result)
        }
        .overlay { importingOverlay }
        // Плашка прогресса скачиваний Bandcamp видна прямо из селектора источников
        // (центр живёт на уровне стека, а не вкладки webview).
        .safeAreaInset(edge: .bottom) {
            WebDownloadsPlate(center: downloadCenter)
        }
    }

    // MARK: - «Из файлов»

    /// Обрабатывает результат `fileImporter`: отдаёт выбранные файлы адаптеру
    /// `FilesImporter` (staging + `AlbumImporter`), затем рескан библиотеки и баннер-итог.
    /// Пустой выбор / отмену игнорируем.
    private func handlePick(_ result: Result<[URL], any Error>) {
        guard case let .success(urls) = result, !urls.isEmpty else { return }
        isImporting = true
        Task {
            let libraryRoot = URL.documentsDirectory
                .appendingPathComponent("Library", isDirectory: true)
            let text: String
            do {
                let results = try await FilesImporter.importPicked(urls, libraryRoot: libraryRoot)
                await rescan()
                text = Self.bannerText(for: results)
            } catch {
                text = "Импорт не удался"
            }
            isImporting = false
            showBanner(text)
        }
    }

    /// Текст баннера-итога импорта: «Импортирован <артист — альбом>» для одного альбома;
    /// для нескольких — их число; пустой результат — «Нечего импортировать». Общий с
    /// системным «Открыть в Zver Media» (`ContentView.onOpenURL`).
    static func bannerText(for results: [ImportResult]) -> String {
        guard let first = results.first else { return "Нечего импортировать" }
        if results.count == 1 {
            let name = first.artist.map { "\($0) — \(first.album)" } ?? first.album
            return "Импортирован \(name)"
        }
        return "Импортировано альбомов: \(results.count)"
    }

    // MARK: - Строки и оверлей

    private func sourceRow(_ title: String, systemImage: String, subtitle: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    @ViewBuilder
    private var importingOverlay: some View {
        if isImporting {
            ZStack {
                Color.black.opacity(0.15).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Импортируем…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.regularMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}
