import Foundation

/// Чистый троттлер/диф состояния плеера для пушей в пульт.
///
/// Плеер обновляет `currentTime` часто (каждый тик), но слать полный `state`
/// на каждый тик — флуд. Mac интерполирует позицию между пушами сам, поэтому
/// эмитим `state` только при значимом изменении (смена трека/playback/очереди/
/// индекса) ИЛИ при сдвиге позиции ≥ порога (seek, перемотка, рассинхрон).
/// Без состояния, без эффектов — TDD без сети.
public enum RemoteStateDiff {
    /// Нужно ли отправить `next` в пульт.
    ///
    /// - `prev == nil` (первое состояние) → всегда true.
    /// - true при изменении `playback`, `current`, `queue` или `currentIndex`.
    /// - для `position` — true только если `|next.position - prev.position| >= positionThreshold`.
    ///
    /// - Parameter positionThreshold: минимальный значимый сдвиг позиции в
    ///   секундах (например `0.5`). Сдвиг меньше порога считается «дрейфом
    ///   тика» и подавляется.
    public static func shouldEmit(prev: RemotePlayerState?,
                                  next: RemotePlayerState,
                                  positionThreshold: Double) -> Bool {
        guard let prev else { return true }

        if prev.playback != next.playback { return true }
        if prev.current != next.current { return true }
        if prev.queue != next.queue { return true }
        if prev.currentIndex != next.currentIndex { return true }

        // Только позиция могла измениться — пушим лишь при значимом сдвиге.
        return abs(next.position - prev.position) >= positionThreshold
    }
}
