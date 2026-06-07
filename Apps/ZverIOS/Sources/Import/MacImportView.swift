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
    @StateObject private var model = MacImportModel()

    var body: some View {
        Group {
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
                                    onBack: { model.deselect() })
            case let .failed(message):
                failed(message)
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
/// На этом этапе — только просмотр того, что Мак готов отдать. Кнопка
/// «Импортировать» появится в S3-11 (докачиваемая загрузка + раскладка).
struct ManifestPreviewView: View {
    let manifest: SyncManifest
    let macName: String
    let onBack: () -> Void

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
