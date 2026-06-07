import SwiftUI

/// Список исходящей очереди со статусами.
///
/// Каркас (S3-8): показывает альбомы в очереди, их статус и кнопку удаления.
/// Сетевая раздача/`confirm` (S3-9) будут менять статусы через
/// `Task { @MainActor in … }`.
struct QueueView: View {
    @ObservedObject var queue: OutgoingQueue

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
