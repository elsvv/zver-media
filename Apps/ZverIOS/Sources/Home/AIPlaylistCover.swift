import SwiftUI

/// Анимированная шейдерная обложка AI-секции: детерминированная палитра от
/// названия (одна секция всегда узнаваема своим цветом), медленное «дыхание»
/// через TimelineView. Заголовок — поверх градиента, как большие плитки
/// Apple Music. Анимация живёт только пока плитка на экране (TimelineView
/// не тикает вне иерархии).
struct AIPlaylistCover: View {
    let title: String
    var subtitle: String?
    var cornerRadius: CGFloat = 14

    /// Базовый оттенок (0..1) из стабильного хэша названия: сид не зависит
    /// от запуска (hashValue у String — рандомизирован, поэтому FNV-1a).
    private var hue: Float {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in title.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Float(hash % 1000) / 1000
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let time = Float(context.date.timeIntervalSinceReferenceDate
                             .truncatingRemainder(dividingBy: 3600))
            GeometryReader { proxy in
                Rectangle()
                    .fill(.white)
                    .colorEffect(ShaderLibrary.aiCover(
                        .float2(Float(proxy.size.width), Float(proxy.size.height)),
                        .float(time),
                        .float(hue)
                    ))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            }
            .padding(12)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
