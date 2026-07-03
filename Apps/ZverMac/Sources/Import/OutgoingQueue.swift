import Foundation
import ZverTransport

/// Один альбом в исходящей очереди: готовый манифест-альбом + папка-источник
/// для раздачи файлов + статус.
///
/// `@MainActor`: создаётся и читается из UI (`QueueView`). Сетевая раздача
/// (S3-9) будет читать `manifestAlbum`/`sourceFolder` и менять `status`.
@MainActor
final class QueuedAlbum: ObservableObject, Identifiable {
    /// Статус альбома в очереди. На этапе каркаса (S3-8) меняется только вручную
    /// из UI; S3-9 свяжет с реальной раздачей/`confirm`.
    enum Status: Equatable, Sendable {
        /// В очереди, ждёт подключения телефона.
        case waiting
        /// Телефон качает альбом.
        case sending
        /// Телефон прислал `confirm` — альбом разложен, можно убирать.
        case delivered
        /// Ошибка при подготовке/раздаче.
        case failed(String)

        var isTerminal: Bool {
            if case .delivered = self { return true }
            return false
        }
    }

    let id: String              // albumId протокола (стабильный)
    let manifestAlbum: ManifestAlbum
    /// Папка, ИЗ КОТОРОЙ раздаются файлы. Для обычного альбома = дропнутая папка;
    /// для DSD = app-managed staging с готовыми FLAC (см. `DSDStaging`).
    let sourceFolder: URL
    /// Папка для учёта доставки (`DeliveredStore`) — всегда ОРИГИНАЛ, дропнутый
    /// пользователем. У DSD `sourceFolder` (staging) ≠ оригинала, поэтому дедуп
    /// автоочереди должен опираться на неизменный источник, а не на staging.
    let deliveredKeyFolder: URL
    @Published var status: Status

    init(manifestAlbum: ManifestAlbum, sourceFolder: URL,
         deliveredKeyFolder: URL? = nil, status: Status = .waiting) {
        self.id = manifestAlbum.id
        self.manifestAlbum = manifestAlbum
        self.sourceFolder = sourceFolder
        self.deliveredKeyFolder = deliveredKeyFolder ?? sourceFolder
        self.status = status
    }
}

/// Исходящая очередь альбомов на раздачу телефону.
///
/// Перезаливка того же `albumId` обновляет элемент на месте (без дублей) —
/// согласовано с детерминированным `AlbumIdentity`. Источник манифеста для
/// сервера (S3-9): собирает `SyncManifest` из непустой очереди.
///
/// `@MainActor`: мутируется из UI. Сетевые колбэки (S3-9) будут переходить сюда
/// через `Task { @MainActor in … }`, не наследуя изоляцию в фоновые очереди.
@MainActor
final class OutgoingQueue: ObservableObject {
    @Published private(set) var albums: [QueuedAlbum] = []

    init(albums: [QueuedAlbum] = []) {
        self.albums = albums
    }

    var isEmpty: Bool { albums.isEmpty }

    /// Добавляет/обновляет альбом по `id`. Перезаливка того же альбома заменяет
    /// прежнюю запись на месте (статус сбрасывается в `.waiting`), не плодя дубли.
    func enqueue(_ album: QueuedAlbum) {
        if let index = albums.firstIndex(where: { $0.id == album.id }) {
            albums[index] = album
        } else {
            albums.append(album)
        }
    }

    /// Убирает альбом из очереди (например, после `confirm` от телефона).
    func remove(id: String) {
        albums.removeAll { $0.id == id }
    }

    /// Очищает доставленные альбомы (терминальный статус).
    func removeDelivered() {
        albums.removeAll { $0.status.isTerminal }
    }

    /// Собирает текущий манифест из очереди (для отдачи телефону в S3-9).
    func currentManifest() -> SyncManifest {
        ManifestBuilder.buildManifest(albums: albums.map(\.manifestAlbum))
    }
}
