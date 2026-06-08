import SwiftUI
import ZverCore

/// Бейдж облачного статуса трека по его ``FileState`` — маленькая иконка справа
/// в ряду трека, рядом с ``TrackFormatBadge``. Читает только `track.fileState`,
/// сеть не дёргает (источник правды — каталог, обновляется ``BackupService``).
///
/// Соответствие состояний (раздел «Жизненный цикл fileState» плана этапа 4):
/// - `backedUp` → облако с галкой (на диске И в облаке, можно выгрузить);
/// - `remote`   → облако (только в облаке, локальной копии нет);
/// - `uploading`   → стрелка вверх в круге (идёт выгрузка);
/// - `downloading` → стрелка вниз в круге (идёт скачивание);
/// - `local`    → пусто (в облаке ещё нет — бейдж не показывается).
///
/// `uploading`/`downloading` — индикатор активности (без точного процента: прогресс
/// в байтах приходит в очередь, но per-track процент в каталоге не хранится; крутилка
/// честнее «застывшего» числа). По завершении состояние меняется на `backedUp`/`remote`
/// и иконка становится статичной — это и есть видимый прогресс жизненного цикла.
struct TrackCloudBadge: View {
    let track: Track

    var body: some View {
        switch track.fileState {
        case .local:
            // В облаке ещё нет — бейджа нет (ряд остаётся чистым, как этап 2/3).
            EmptyView()
        case .backedUp:
            icon("checkmark.icloud", tint: .green)
        case .remote:
            icon("icloud", tint: .secondary)
        case .uploading:
            activity(systemImage: "arrow.up")
        case .downloading:
            activity(systemImage: "arrow.down")
        }
    }

    /// Статичная облачная иконка заданного оттенка.
    private func icon(_ systemName: String, tint: some ShapeStyle) -> some View {
        Image(systemName: systemName)
            .font(.caption)
            .foregroundStyle(tint)
            .accessibilityLabel(Self.accessibilityLabel(for: track.fileState))
    }

    /// Индикатор активной передачи: крутящийся прогресс + направление стрелкой.
    private func activity(systemImage: String) -> some View {
        ZStack {
            ProgressView()
                .controlSize(.mini)
            Image(systemName: systemImage)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(Self.accessibilityLabel(for: track.fileState))
    }

    /// Голосовая подпись статуса (VoiceOver).
    static func accessibilityLabel(for state: FileState) -> String {
        switch state {
        case .local: return "Только на устройстве"
        case .uploading: return "Выгружается в облако"
        case .backedUp: return "В облаке и на устройстве"
        case .remote: return "Только в облаке"
        case .downloading: return "Скачивается из облака"
        }
    }
}
