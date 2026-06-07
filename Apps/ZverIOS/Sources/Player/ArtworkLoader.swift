import UIKit
import ZverCore
import ZverMetadata

/// Ленивая загрузка обложек: кэш → встроенная (MetadataReader) →
/// файл из папки трека (track.artworkFileURL) → nil.
/// Кэш в памяти по track.id (NSCache сам вытесняет при нехватке памяти).
@MainActor
final class ArtworkLoader {
    private let cache = NSCache<NSString, UIImage>()

    func artwork(for track: Track) async -> UIImage? {
        let key = track.id as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = await Self.load(track) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Вне MainActor (nonisolated async → глобальный экзекьютор):
    /// чтение метаданных/файла и декодирование — не на главном потоке.
    private nonisolated static func load(_ track: Track) async -> UIImage? {
        if let data = (try? await MetadataReader.read(url: track.url))?.artworkData,
           let image = UIImage(data: data) {
            return image
        }
        guard let fileURL = track.artworkFileURL,
              let data = try? Data(contentsOf: fileURL)
        else { return nil }
        return UIImage(data: data)
    }
}
