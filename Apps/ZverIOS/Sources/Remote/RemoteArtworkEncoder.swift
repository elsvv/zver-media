import UIKit

/// Кодирование обложки для канала пульта: даунскейл до `maxSide` и JPEG ~0.8.
/// Обложки в библиотеке бывают 1500–3000px — гонять такое по WS незачем,
/// гриду Мака хватает 600px (~50–150 КБ).
enum RemoteArtworkEncoder {
    nonisolated static func jpeg(from image: UIImage, maxSide: CGFloat) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }

        let scale = min(maxSide / longest, 1)
        let target = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())

        // scale == 1 (и так маленькая) — не перерисовываем, только кодируем.
        guard scale < 1 else { return image.jpegData(compressionQuality: 0.8) }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // пиксели == пункты: без ретина-удвоения размера
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}
