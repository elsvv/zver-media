import SwiftUI
import ZverCore

/// Контекст-меню и swipe-действия облака для ряда трека: «Выгрузить» (для
/// `backedUp`) и «Скачать» (для `remote`). Делегирует ``LibraryStore`` (обёртки
/// `offload`/`download` → ``BackupService`` + republish). Действие появляется
/// только в применимом состоянии (раздел «Жизненный цикл fileState» плана этапа 4):
/// - `backedUp` (на диске И в облаке) → «Выгрузить» (удалить локальную копию);
/// - `remote` (только в облаке) → «Скачать» (вернуть файл на устройство);
/// - прочие (`local`/`uploading`/`downloading`) → действий нет (передача идёт или
///   трек ещё не в облаке).
///
/// `contextMenu` (долгий тап) и `swipeActions` (свайп) дают оба привычных жеста.
/// Сами операции async (сеть/ФС) — запускаются в `Task`, UI обновляется через
/// republish внутри обёрток `LibraryStore`.
private struct CloudActionsModifier: ViewModifier {
    let track: Track
    let store: LibraryStore

    func body(content: Content) -> some View {
        content
            .contextMenu { menuItems }
            .swipeActions(edge: .leading, allowsFullSwipe: false) { swipeItems }
    }

    @ViewBuilder
    private var menuItems: some View {
        switch track.fileState {
        case .backedUp:
            Button {
                Task { await store.offload(track: track) }
            } label: {
                Label("Выгрузить", systemImage: "icloud.and.arrow.up")
            }
        case .remote:
            Button {
                Task { await store.download(track: track) }
            } label: {
                Label("Скачать", systemImage: "icloud.and.arrow.down")
            }
        case .local, .uploading, .downloading:
            EmptyView()
        }
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
    /// Вешает на ряд трека облачные действия «Выгрузить»/«Скачать» (контекст-меню +
    /// swipe), доступные в соответствующем `fileState`.
    func cloudActions(for track: Track, store: LibraryStore) -> some View {
        modifier(CloudActionsModifier(track: track, store: store))
    }
}
