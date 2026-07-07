import Foundation

/// Ротация категорий external-секций на один refresh «Главной».
///
/// ЧИСТАЯ функция (как ``HomeFeedPrompt``): всё изменчивое состояние приходит
/// параметрами — наличие одержимостей, webSearch активного профиля и `offset`
/// round-robin окна (приложение хранит его в UserDefaults
/// `home.categoryRotation` и после успешного refresh записывает `nextOffset`).
///
/// Состав заказа (дизайн «Предложка v2», пайплайн refresh, шаг 1):
/// - всегда `deeper-discography`; `similar-to-obsession` — при одержимостях;
///   `fresh-releases` — только при `webSearch == true` (замыкает список);
/// - плюс 2–3 категории из ротирующегося пула — окно от `offset` с заворотом;
/// - итого 4–5 категорий.
public enum DiscoveryRotation {
    /// Пул ротации: всё, кроме якорей (similar/deeper) и условной fresh.
    public static let rotatingPool: [DiscoveryCategory] = [
        .missedClassics, .digDeeper, .sideways, .sceneDive, .timeTravel,
    ]

    /// Заказ категорий на refresh + следующий offset округлённого окна.
    public static func plan(
        hasObsessions: Bool,
        webSearch: Bool,
        offset: Int
    ) -> (categories: [DiscoveryCategory], nextOffset: Int) {
        var fixedHead: [DiscoveryCategory] = []
        if hasObsessions { fixedHead.append(.similarToObsession) }
        fixedHead.append(.deeperDiscography)
        let fixedTail: [DiscoveryCategory] = webSearch ? [.freshReleases] : []

        // Добираем ротирующимися до 5 категорий, но не меньше 2 и не больше 3
        // ротирующихся — итог всегда 4–5.
        let fixedCount = fixedHead.count + fixedTail.count
        let rotatingCount = min(max(5 - fixedCount, 2), 3)

        let pool = rotatingPool
        let start = ((offset % pool.count) + pool.count) % pool.count
        let rotating = (0..<rotatingCount).map { pool[(start + $0) % pool.count] }

        return (categories: fixedHead + rotating + fixedTail,
                nextOffset: (start + rotatingCount) % pool.count)
    }
}
