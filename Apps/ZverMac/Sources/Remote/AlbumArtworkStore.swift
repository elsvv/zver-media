import AppKit
import Foundation
import ZverTransport

/// Кэш обложек альбомов iPhone для грида библиотеки и now-playing пульта.
///
/// Двухуровневый: `NSCache` в памяти (быстрый, вытесняется под давлением) + диск
/// `~/Library/Caches/ZverMac/Artwork/{sha256(albumId)}.jpg` (переживает
/// перезапуск). Плитка при появлении зовёт ``request(for:)``: сначала память,
/// потом диск, и только при промахе — сеть (`requestArtwork` через
/// ``onNeedArtwork``). Входящий `.artwork(albumId, data)` кладётся ``ingest(albumId:data:)``.
///
/// Форматом обложки владеет iPhone (JPEG ≤600px): на диск пишем принятые байты
/// как есть, в память — декодированный `NSImage`. Дедуп запросов через
/// `inFlight`: пока обложка «в полёте» (ждём ответ или читаем диск), повторный
/// `request` — no-op, сеть не флудим.
///
/// Concurrency: `@MainActor` (память/`inFlight`/`revision` трогаются только с
/// главного потока). Дисковый ввод-вывод уходит на `Task.detached` как `Data`
/// (Sendable); `NSImage` через границу актора не передаём — декодируем/кодируем
/// на `@MainActor` (обложки мелкие). SwiftUI перерисовывается по `@Published
/// revision` — вью читают `image(for:)`, обновляются на инкремент.
@MainActor
final class AlbumArtworkStore: ObservableObject {
    /// Счётчик обновлений кэша — дёргает перерисовку вью, читающих `image(for:)`.
    @Published private(set) var revision = 0

    /// Отправитель сетевого запроса обложки (ставится координатором →
    /// `requestArtwork(albumId:)`). До установки промах диска просто не тянет сеть.
    var onNeedArtwork: ((String) -> Void)?

    private let memory = NSCache<NSString, NSImage>()
    /// Обложки «в полёте»: диск читается или сеть запрошена — не дублируем.
    private var inFlight: Set<String> = []
    /// Директория дискового кэша (создаётся лениво при первой записи).
    private let diskDirectory: URL

    init() {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDirectory = base
            .appendingPathComponent("ZverMac", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }

    /// Обложка из памяти (или nil — тогда плитка рисует заглушку и зовёт `request`).
    func image(for albumId: String) -> NSImage? {
        memory.object(forKey: albumId as NSString)
    }

    /// Лениво подгружает обложку альбома: память → диск → сеть. Идемпотентно —
    /// уже загруженное или уже запрошенное не трогает.
    func request(for albumId: String) {
        guard memory.object(forKey: albumId as NSString) == nil else { return }
        guard !inFlight.contains(albumId) else { return }
        inFlight.insert(albumId)

        let url = diskURL(for: albumId)
        Task { [weak self] in
            // Диск читаем вне главного потока (Data — Sendable); декод — на @MainActor.
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let self else { return }
            if let data, let image = NSImage(data: data) {
                self.memory.setObject(image, forKey: albumId as NSString)
                self.inFlight.remove(albumId)
                self.revision &+= 1
            } else {
                // Диска нет — просим у iPhone. inFlight держим до ответа (или reset),
                // чтобы грид не флудил `requestArtwork` на каждый повторный onAppear.
                self.onNeedArtwork?(albumId)
            }
        }
    }

    /// Принимает обложку от iPhone: декодирует в память, пишет байты на диск,
    /// снимает флаг «в полёте», дёргает перерисовку.
    func ingest(albumId: String, data: Data) {
        inFlight.remove(albumId)
        guard let image = NSImage(data: data) else { return }
        memory.setObject(image, forKey: albumId as NSString)
        revision &+= 1

        let url = diskURL(for: albumId)
        let directory = diskDirectory
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Сброс при потере соединения/смене iPhone: чистим память и «в полёте»
    /// (диск оставляем — обложки переживают переподключение и грузятся с диска).
    func reset() {
        memory.removeAllObjects()
        inFlight.removeAll()
        revision &+= 1
    }

    /// Путь файла обложки на диске: имя — sha256 от albumId (albumId содержит
    /// `\u{1}` и произвольные символы — в имя файла напрямую не годится).
    private func diskURL(for albumId: String) -> URL {
        let name = Sha256.hash(Data(albumId.utf8))
        return diskDirectory.appendingPathComponent(name).appendingPathExtension("jpg")
    }
}

/// Вывод `albumId` из трека — тем же способом, что и iPhone
/// (`RemoteLibraryBuilder.albumId`: `artist + "\u{1}" + album`). Нужен, чтобы
/// обложка now-playing в пульте искалась тем же ключом, что и в гриде библиотеки.
enum RemoteAlbumID {
    static func of(track: RemoteTrack) -> String {
        (track.artist ?? "") + "\u{1}" + (track.album ?? "")
    }
}
