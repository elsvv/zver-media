import SwiftUI
import ZverTransport

/// Корневой экран «Импорт с Мака».
///
/// Состояния по фазе модели:
/// - `.idle` — список найденных Маков (браузинг `_zver._tcp`).
/// - `.needsCode` — экран ввода кода (`PairingView`).
/// - `.connecting` — индикатор обмена.
/// - `.ready(manifest)` — предпросмотр очереди Мака (альбомы/треки).
/// - `.failed` — сообщение об ошибке с возвратом к списку.
///
/// Браузер запускается при появлении экрана и останавливается при исчезновении
/// (живёт ровно пока открыт экран — лессон из плана). Сам трансфер файлов — S3-11.
struct MacImportView: View {
    @StateObject private var model: MacImportModel

    /// `rescan` инъектируется из `ContentView` — обёртка над `LibraryStore.refresh`,
    /// которую модель/координатор дёргают после раскладки альбома (reconcile из
    /// sidecar). `@StateObject` строится один раз через `init(wrappedValue:)`.
    init(rescan: @escaping @MainActor () async -> Void = {}) {
        _model = StateObject(wrappedValue: MacImportModel(rescan: rescan))
    }

    var body: some View {
        Group {
            if let coordinator = model.importCoordinator {
                ImportProgressView(coordinator: coordinator,
                                   onDone: { model.dismissImport() })
            } else {
                switch model.phase {
                case .idle:
                    macList
                case .needsCode:
                    PairingView(model: model, macName: model.selectedMac?.name ?? "Мак")
                case .connecting:
                    connecting
                case let .ready(manifest):
                    ManifestPreviewView(manifest: manifest,
                                        macName: model.selectedMac?.name ?? "Мак",
                                        onBack: { model.deselect() },
                                        onImport: { model.startImport() })
                case let .failed(message):
                    failed(message)
                }
            }
        }
        .navigationTitle("Импорт с Мака")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.startBrowsing() }
        .onDisappear { model.stopBrowsing() }
    }

    // MARK: - Список Маков

    @ViewBuilder
    private var macList: some View {
        if model.discoveredMacs.isEmpty {
            ContentUnavailableView {
                Label("Ищем ваш Mac", systemImage: "magnifyingglass")
            } description: {
                Text("Откройте Zver на Маке и добавьте альбомы в очередь. Устройства должны быть в одной сети Wi-Fi.")
            }
        } else {
            List(model.discoveredMacs, id: \.name) { mac in
                Button {
                    model.select(mac)
                } label: {
                    HStack {
                        Label(mac.name, systemImage: "laptopcomputer")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
            }
        }
    }

    // MARK: - Промежуточные состояния

    private var connecting: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Подключаемся к «\(model.selectedMac?.name ?? "Маку")»…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Не получилось", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("К списку Маков") { model.deselect() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Предпросмотр исходящей очереди Мака из манифеста: альбомы и их треки.
///
/// Кнопка «Импортировать» запускает докачиваемую загрузку очереди (S3-11):
/// файлы скачиваются с докачкой, сверяются по sha256, раскладываются в библиотеку,
/// после чего альбом подтверждается Маку.
struct ManifestPreviewView: View {
    let manifest: SyncManifest
    let macName: String
    let onBack: () -> Void
    let onImport: () -> Void

    var body: some View {
        Group {
            if manifest.albums.isEmpty {
                ContentUnavailableView {
                    Label("Очередь пуста", systemImage: "tray")
                } description: {
                    Text("На «\(macName)» нет альбомов в очереди. Добавьте их в Zver на Маке.")
                }
            } else {
                List {
                    ForEach(manifest.albums, id: \.id) { album in
                        Section {
                            ForEach(album.tracks, id: \.fileName) { track in
                                trackRow(track)
                            }
                        } header: {
                            albumHeader(album)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { importBar }
            }
        }
        .navigationTitle("Очередь Мака")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Назад", action: onBack)
            }
        }
    }

    /// Нижняя панель с кнопкой запуска импорта всей очереди.
    private var importBar: some View {
        Button(action: onImport) {
            Label("Импортировать на iPhone", systemImage: "arrow.down.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private func albumHeader(_ album: ManifestAlbum) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(album.title)
                .font(.headline)
                .textCase(nil)
            if let artist = album.artist {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
    }

    private func trackRow(_ track: ManifestTrack) -> some View {
        HStack {
            if let number = track.trackNumber {
                Text("\(number)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
            Text(track.title)
                .lineLimit(1)
            Spacer()
            Text(qualityLabel(for: track))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    /// Краткая метка качества: «24/96» (бит/кГц) либо просто кГц для 16-бит/CD.
    private func qualityLabel(for track: ManifestTrack) -> String {
        let khz = String(format: "%g", Double(track.sampleRate) / 1000)
        if let bits = track.bitDepth {
            return "\(bits)/\(khz)"
        }
        return "\(khz) кГц"
    }
}

/// Экран прогресса импорта очереди: по альбому — фаза и индикатор готовности.
/// Координатор публикует состояние; вьюха его отражает. По завершении (все
/// альбомы готовы или часть упала) — кнопка возврата к предпросмотру.
struct ImportProgressView: View {
    @ObservedObject var coordinator: ImportCoordinator
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(coordinator.albums) { album in
                albumRow(album)
            }
            if isFinished {
                footer
            }
        }
        .navigationTitle("Импорт")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isFinished: Bool {
        switch coordinator.phase {
        case .finished, .failed: return true
        case .idle, .running: return false
        }
    }

    @ViewBuilder
    private func albumRow(_ album: ImportCoordinator.AlbumImport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusIcon(album.phase)
            }
            phaseDetail(album.phase)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusIcon(_ phase: ImportCoordinator.AlbumPhase) -> some View {
        switch phase {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .downloading, .finalizing:
            ProgressView()
        }
    }

    @ViewBuilder
    private func phaseDetail(_ phase: ImportCoordinator.AlbumPhase) -> some View {
        switch phase {
        case .waiting:
            Text("Ожидает").font(.caption).foregroundStyle(.secondary)
        case let .downloading(progress):
            ProgressView(value: progress)
                .tint(.accentColor)
        case .finalizing:
            Text("Завершаем…").font(.caption).foregroundStyle(.secondary)
        case .done:
            Text("Готово").font(.caption).foregroundStyle(.green)
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if case let .failed(message) = coordinator.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Готово", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding()
        .background(.bar)
    }
}
