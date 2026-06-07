import UIKit
import ZverCore
import ZverMetadata

/// Ленивая загрузка обложек: кэш → файл из папки трека (track.artworkFileURL)
/// → встроенная (MetadataReader) → nil.
/// Файл из папки приоритетнее встроенной: `LibraryScanner` выставляет
/// `artworkFileURL` только когда либо есть sidecar-обложка (правленая на Маке —
/// должна побеждать встроенную), либо встроенной нет вовсе. Поэтому проба файла
/// первой корректна: встроенная-единственная обложка не теряется (там
/// artworkFileURL == nil), а правка с Мака выигрывает.
/// Кэш в памяти по track.id (NSCache сам вытесняет при нехватке памяти).
/// Параллельные запросы одного трека дедуплицируются: грузит первый,
/// остальные ждут его Task.
@MainActor
final class ArtworkLoader {
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Синхронный peek в кэш: UI показывает обложку сразу, без прохода
    /// через nil (нет мигания плейсхолдером при смене трека).
    func cached(for track: Track) -> UIImage? {
        cache.object(forKey: track.id as NSString)
    }

    func artwork(for track: Track) async -> UIImage? {
        if let cached = cached(for: track) {
            return cached
        }
        if let running = inFlight[track.id] {
            return await running.value
        }
        let task = Task { await Self.load(track) }
        inFlight[track.id] = task
        let image = await task.value
        inFlight[track.id] = nil
        if let image {
            cache.setObject(image, forKey: track.id as NSString)
        }
        return image
    }

    /// Вне MainActor (nonisolated async → глобальный экзекьютор):
    /// чтение метаданных/файла и декодирование — не на главном потоке.
    ///
    /// Сначала пробуем файл из папки (`artworkFileURL`): он несёт правленую на
    /// Маке обложку из sidecar (должна побеждать встроенную) либо фоллбэк-обложку
    /// при отсутствии встроенной. Только если файла нет/не читается — встроенная.
    private nonisolated static func load(_ track: Track) async -> UIImage? {
        if let fileURL = track.artworkFileURL,
           let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            return image
        }
        guard let data = (try? await MetadataReader.read(url: track.url))?.artworkData
        else { return nil }
        return UIImage(data: data)
    }
}
