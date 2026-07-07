import SwiftUI
import ZverCore

/// Индикатор «сейчас играет» в ряду трека: анимированный waveform акцентного
/// цвета. Ставится на место номера трека (та же ширина колонки), чтобы ряды
/// не «прыгали» при смене текущего трека. Пауза — символ статичен.
struct NowPlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying)
            .font(.callout)
            .foregroundStyle(.tint)
    }
}

extension PlayerEngine {
    /// Трек `track` — текущий в очереди воспроизведения (для подсветки рядов).
    func isCurrent(_ track: Track) -> Bool {
        queue.current?.id == track.id
    }
}
