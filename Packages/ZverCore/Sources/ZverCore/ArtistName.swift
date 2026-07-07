import Foundation

/// Чистые функции нормализации имени артиста для case-insensitive объединения.
///
/// Артисты, различающиеся только регистром/окружающими пробелами
/// («King Gizzard & the lizard wizard» и «King Gizzard & The lizard wizard»),
/// — один артист. Ключ объединяет варианты, `canonical` выбирает отображаемое
/// написание (та же идея, что `displayTitle` у `AlbumGroup`).
public enum ArtistName {
    /// Ключ объединения: trim пробелов + `lowercased()`. Пустое/пробельное имя
    /// и nil дают nil (у трека нет артиста — его нельзя группировать по артисту).
    public static func key(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    /// Отображаемое написание артиста: вариант, встречающийся среди `variants`
    /// большинством голосов; тай-брейк — первое появление (как `max(by:)` в
    /// `AlbumGroup.displayTitle` — обновляет только на строго большем счёте,
    /// поэтому при равенстве остаётся более ранний). Ожидается, что все варианты
    /// имеют один `key`; вызывать имеет смысл только для непустого ключа.
    /// Пустая или полностью пробельная последовательность → пустая строка.
    public static func canonical(_ variants: some Sequence<String>) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for variant in variants {
            let trimmed = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if counts[trimmed] == nil { order.append(trimmed) }
            counts[trimmed, default: 0] += 1
        }
        return order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ""
    }
}
