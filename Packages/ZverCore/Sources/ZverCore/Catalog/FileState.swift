import Foundation

/// Состояние локальной/облачной копии трека в каталоге.
///
/// rawValue — строки для колонки `track.fileState` (читаемы в SQLite-дампе).
/// Граф жизненного цикла (этап 4 «Яндекс.Диск»):
/// ```
/// local ──upload──▶ uploading ──ok+shaОК──▶ backedUp ──«Выгрузить»──▶ remote
///                       └────fail──────────┘ (откат в local)
/// remote ──«Скачать»──▶ downloading ──ok+shaОК──▶ backedUp
///                            └────fail──────────▶ remote (откат)
/// ```
public enum FileState: String, Codable, Sendable, CaseIterable {
    /// Файл на устройстве, в облаке ещё нет (новый/импортированный трек).
    case local
    /// Файл на устройстве, идёт выгрузка в облако.
    case uploading
    /// Файл на устройстве И подтверждён в облаке (`cloudSha` совпал).
    case backedUp
    /// Файл только в облаке (локальная копия удалена); подразумевает `cloudSha`.
    case remote
    /// Идёт скачивание из облака на устройство.
    case downloading

    /// Есть ли физический файл на устройстве (true для всех, кроме `remote`).
    public var hasLocalFile: Bool {
        self != .remote
    }

    /// Подтверждено ли наличие в облаке (`backedUp`/`remote`).
    public var isInCloud: Bool {
        self == .backedUp || self == .remote
    }

    /// Валидно ли ребро графа жизненного цикла `self → target`.
    ///
    /// Чистая функция; идемпотентность перехода обеспечивает `CatalogStore`
    /// (повтор перехода после сбоя продолжает, не ломает). Переход в то же
    /// состояние — НЕ ребро (нечего менять).
    public func canTransition(to target: FileState) -> Bool {
        switch (self, target) {
        case (.local, .uploading),       // начали выгрузку
             (.uploading, .backedUp),    // выгрузка успешна + sha совпал
             (.uploading, .local),       // выгрузка провалилась — откат
             (.backedUp, .remote),       // «Выгрузить»: удалили локальную копию
             (.remote, .downloading),    // «Скачать»: начали скачивание
             (.downloading, .backedUp),  // скачивание успешно + sha совпал
             (.downloading, .remote):    // скачивание провалилось — откат
            return true
        default:
            return false
        }
    }
}
