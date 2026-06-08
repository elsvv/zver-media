import SwiftUI
import ZverCore

/// Swipe-действия облака для ряда трека: «Выгрузить» (для `backedUp`) и «Скачать»
/// (для `remote`). Делегирует ``LibraryStore`` (обёртки `offload`/`download` →
/// ``BackupService`` + republish). Действие появляется только в применимом
/// состоянии (раздел «Жизненный цикл fileState» плана этапа 4):
/// - `backedUp` (на диске И в облаке) → «Выгрузить» (удалить локальную копию);
/// - `remote` (только в облаке) → «Скачать» (вернуть файл на устройство);
/// - прочие (`local`/`uploading`/`downloading`) → действий нет (передача идёт или
///   трек ещё не в облаке).
///
/// Облачные действия даём ТОЛЬКО через `swipeActions` (свайп): контекст-меню
/// (долгий тап) ряда занято меню «В плейлист…» (`addToPlaylistMenu`). Два
/// вложенных `.contextMenu` на одном ряду конфликтуют — внешний затеняет
/// внутренний (для `local`/`uploading`/`downloading` он к тому же пустой), что
/// ломало бы «В плейлист…». Сами операции async (сеть/ФС) — запускаются в `Task`,
/// UI обновляется через republish внутри обёрток `LibraryStore`.
private struct CloudActionsModifier: ViewModifier {
    let track: Track
    let store: LibraryStore

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) { swipeItems }
    }

    @ViewBuilder
    private var swipeItems: some View {
        switch track.fileState {
        case .backedUp:
            Button {
                Task { await store.offload(track: track) }
            } label: {
                Label("Выгрузить", systemImage: "icloud.and.arrow.up")
            }
            .tint(.blue)
        case .remote:
            Button {
                Task { await store.download(track: track) }
            } label: {
                Label("Скачать", systemImage: "icloud.and.arrow.down")
            }
            .tint(.green)
        case .local, .uploading, .downloading:
            EmptyView()
        }
    }
}

extension View {
    /// Вешает на ряд трека облачные действия «Выгрузить»/«Скачать» (swipe),
    /// доступные в соответствующем `fileState`.
    func cloudActions(for track: Track, store: LibraryStore) -> some View {
        modifier(CloudActionsModifier(track: track, store: store))
    }
}
