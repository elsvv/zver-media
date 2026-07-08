import Foundation

/// Результат генерации «Главной»: набор секций-подборок.
///
/// Строго `Codable` — это же и схема ответа модели (её просим вернуть JSON),
/// и формат дискового кэша в аппе (`homefeed.json`).
public struct HomeFeed: Codable, Equatable, Sendable {
    public let sections: [HomeSection]
    public init(sections: [HomeSection]) {
        self.sections = sections
    }
}

/// Одна секция ленты.
///
/// ВАЖНО (уточнение дизайна): снапшот отдаёт ТОЛЬКО альбомы (id треков в нём нет),
/// поэтому поддерживаем два вида — `albums` (список id альбомов библиотеки) и
/// `external` (внешние рекомендации «что скачать»). Секций из треков (плейлистов)
/// на этом этапе НЕ делаем — они отложены, и промпт их не просит.
public struct HomeSection: Codable, Equatable, Sendable {
    /// Вид секции. Других значений быть не должно (промпт это запрещает).
    public enum Kind: String, Codable, Equatable, Sendable {
        /// Подборка из библиотеки: непустой ``HomeSection/albumIds``.
        case albums
        /// Внешние рекомендации: непустой ``HomeSection/items``.
        case external
    }

    /// Цепкий короткий заголовок.
    public let title: String
    /// Пояснение, за счёт чего собрана секция (необязательно).
    public let subtitle: String?
    /// Короткие чипы-ярлыки для UI (необязательно).
    public let tags: [String]?
    /// Вид секции.
    public let kind: Kind
    /// Слаг категории discovery (см. ``DiscoveryCategory``) — эхо от модели для
    /// external-секций: нужен ротации, фидбек-метрикам и UI. Опционален ради
    /// обратной совместимости: старый кэш `homefeed.json` и ответы без слага
    /// декодятся в `nil` (секция живёт без категории). Тип — String, а не enum:
    /// незнакомый слаг от модели не должен ронять декод всей ленты.
    public let category: String?
    /// Id альбомов библиотеки — только для `kind == .albums`.
    public let albumIds: [String]?
    /// Внешние рекомендации — только для `kind == .external`.
    public let items: [ExternalItem]?

    public init(
        title: String,
        subtitle: String?,
        tags: [String]?,
        kind: Kind,
        category: String? = nil,
        albumIds: [String]?,
        items: [ExternalItem]?
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tags = tags
        self.kind = kind
        self.category = category
        self.albumIds = albumIds
        self.items = items
    }
}

/// Внешняя рекомендация «скачать бы»: реальный релиз ВНЕ библиотеки + объяснение.
public struct ExternalItem: Codable, Equatable, Sendable {
    public let artist: String
    public let album: String
    public let year: Int?
    /// 1–2 предложения: почему зайдёт именно этому слушателю.
    public let reason: String

    public init(artist: String, album: String, year: Int?, reason: String) {
        self.artist = artist
        self.album = album
        self.year = year
        self.reason = reason
    }
}
