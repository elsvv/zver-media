import SwiftUI

/// Список исходящей очереди со статусами.
///
/// Каркас (S3-8): показывает альбомы в очереди, их статус и кнопку удаления.
/// Сетевая раздача/`confirm` (S3-9) будут менять статусы через
/// `Task { @MainActor in … }`.
struct QueueView: View {
    @ObservedObject var queue: OutgoingQueue
    @ObservedObject var server: ServerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Очередь отправки")
                    .font(.headline)
                Spacer()
                if !queue.isEmpty {
                    Text("\(queue.albums.count)")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            content
            Divider()
            ServerStatusPanel(server: server, queueIsEmpty: queue.isEmpty)
        }
    }

    @ViewBuilder
    private var content: some View {
        if queue.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Очередь пуста")
                    .foregroundStyle(.secondary)
                Text("Перетащите папку альбома в окно, чтобы добавить.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else {
            List {
                ForEach(queue.albums) { album in
                    QueueRow(album: album) {
                        queue.remove(id: album.id)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// Одна строка очереди: альбом + статус + кнопка удаления.
private struct QueueRow: View {
    @ObservedObject var album: QueuedAlbum
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(album.manifestAlbum.title)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    if let artist = album.manifestAlbum.artist {
                        Text(artist)
                    }
                    Text("· \(album.manifestAlbum.tracks.count) тр.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Убрать из очереди")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch album.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .sending:
            ProgressView().controlSize(.small)
        case .delivered:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var statusText: String {
        switch album.status {
        case .waiting: return "Ждёт"
        case .sending: return "Отправка…"
        case .delivered: return "Доставлен"
        case .failed(let message): return message
        }
    }
}

/// Нижняя панель очереди: статус раздачи в сети + сопряжение телефона.
///
/// Показывает, слушает ли сервер (порт), 6-значный код сопряжения при открытом
/// окне pairing и результат сопряжения. Сервер стартует автоматически при
/// непустой очереди (`ServerCoordinator`), здесь — только индикация и запуск/
/// остановка окна pairing.
private struct ServerStatusPanel: View {
    @ObservedObject var server: ServerCoordinator
    let queueIsEmpty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            pairingSection
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch server.status {
        case .stopped:
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
        case .running:
            Image(systemName: "wifi").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var statusText: String {
        switch server.status {
        case .stopped:
            return queueIsEmpty ? "Очередь пуста — раздача выключена" : "Раздача не запущена"
        case let .running(port):
            return "Раздаю в сети (порт \(port))"
        case let .failed(message):
            return message
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        if let code = server.pairing.code {
            VStack(alignment: .leading, spacing: 4) {
                Text("Код сопряжения")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(spacedCode(code))
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.semibold)
                Text("Введите этот код на iPhone в экране «Импорт с Мака».")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Скрыть код") { server.stopPairing() }
                    .controlSize(.small)
            }
        } else if server.pairing.didPair {
            Label("iPhone сопряжён", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Button("Сопрячь ещё устройство") { server.startPairing() }
                .controlSize(.small)
                .disabled(queueIsEmpty)
        } else {
            Button("Сопрячь iPhone") { server.startPairing() }
                .controlSize(.small)
                .disabled(queueIsEmpty)
            if queueIsEmpty {
                Text("Добавьте альбом в очередь, чтобы запустить раздачу.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Разбивает код на две тройки для читаемости («123 456»).
    private func spacedCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<mid]) \(code[mid...])"
    }
}
