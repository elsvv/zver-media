import Foundation

/// Устойчивый разбор ответа модели в ``HomeFeed``.
///
/// Модели любят обёртки (```json … ```), преамбулы («Вот ваша лента:») и
/// галлюцинации (id несуществующих альбомов). Парсер к этому терпим:
/// 1) вырезает ПЕРВЫЙ сбалансированный JSON-объект из текста (мимо фенсов/преамбул);
/// 2) декодит его в ``HomeFeed``;
/// 3) чистит: в `albums`-секциях выкидывает id не из `validAlbumIds`, дропает
///    секции, оставшиеся пустыми, и схлопывает список до максимум 8 секций.
///
/// Если после чистки не осталось ни одной секции (или JSON не найден/не декодится)
/// — бросает ``BrainError/badResponse(_:)``.
public enum HomeFeedParser {
    /// Верхняя граница числа секций в ленте (совпадает с потолком из промпта).
    static let maxSections = 8

    public static func parse(_ text: String, validAlbumIds: Set<String>) throws -> HomeFeed {
        guard let json = extractFirstJSONObject(text) else {
            throw BrainError.badResponse("в ответе не найден JSON-объект")
        }

        let raw: HomeFeed
        do {
            raw = try JSONDecoder().decode(HomeFeed.self, from: Data(json.utf8))
        } catch {
            throw BrainError.badResponse("JSON не соответствует схеме HomeFeed: \(error)")
        }

        let cleaned = sanitize(raw.sections, validAlbumIds: validAlbumIds)
        guard !cleaned.isEmpty else {
            throw BrainError.badResponse("после фильтрации не осталось валидных секций")
        }
        return HomeFeed(sections: cleaned)
    }

    // MARK: - Чистка

    /// Отсев галлюцинаций и пустых секций + схлопывание до ``maxSections``.
    static func sanitize(_ sections: [HomeSection], validAlbumIds: Set<String>) -> [HomeSection] {
        let kept = sections.compactMap { section -> HomeSection? in
            switch section.kind {
            case .albums:
                // Оставляем только реально существующие id (порядок сохраняем).
                let valid = (section.albumIds ?? []).filter(validAlbumIds.contains)
                guard !valid.isEmpty else { return nil }
                return HomeSection(
                    title: section.title,
                    subtitle: section.subtitle,
                    tags: section.tags,
                    kind: .albums,
                    albumIds: valid,
                    items: nil
                )
            case .external:
                // Внешние элементы не валидируем по библиотеке — они и должны быть
                // ВНЕ неё; но пустую секцию (без items) выкидываем.
                let items = section.items ?? []
                guard !items.isEmpty else { return nil }
                return HomeSection(
                    title: section.title,
                    subtitle: section.subtitle,
                    tags: section.tags,
                    kind: .external,
                    albumIds: nil,
                    items: items
                )
            }
        }
        return Array(kept.prefix(maxSections))
    }

    // MARK: - Вырезание JSON

    /// Возвращает первый сбалансированный `{ … }`-объект из текста или `nil`.
    ///
    /// Ищем первую `{`, дальше идём по символам, считая глубину `{`/`}` и уважая
    /// строковые литералы (внутри `"…"` скобки не считаются, `\"` не закрывает
    /// строку). Так преамбулы, markdown-фенсы и хвост после объекта отсекаются.
    static func extractFirstJSONObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        // Скобки не сбалансировались — валидного объекта нет.
        return nil
    }
}
