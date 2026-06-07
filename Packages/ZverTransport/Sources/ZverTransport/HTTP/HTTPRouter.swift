import Foundation

/// Чистый роутер путей протокола синка.
///
/// Маппит request-target в `Route`. Эндпоинты: `/manifest`, `/pair`, `/confirm`,
/// `/album/<albumId>/<fileName>`. Percent-декодирует сегменты `albumId`/`fileName`
/// и ЖЁСТКО защищает от path traversal: декодированный сегмент не должен содержать
/// `/`, начинаться с `/`, быть `.`/`..`, пустым/из одних пробелов или содержать
/// нулевой байт. Любое нарушение → `.notFound` (никаких 4xx-с-намёком, чтобы не
/// сливать структуру ФС).
public enum HTTPRouter {
    /// Разрешённый маршрут.
    public enum Route: Equatable, Sendable {
        case manifest
        case album(id: String, fileName: String)
        case pair
        case confirm
        case notFound
    }

    /// Резолвит путь (request-target) в маршрут.
    ///
    /// Query string (`?...`) отбрасывается. Декодирование и проверки traversal —
    /// посегментно: путь сначала бьётся по СЫРЫМ `/`, затем каждый сегмент
    /// percent-декодируется и валидируется (так `%2F` внутри сегмента не создаёт
    /// фальшивого разделителя и отлавливается как traversal).
    public static func resolve(path: String) -> Route {
        // Отрезаем query string.
        let pathOnly: String
        if let q = path.firstIndex(of: "?") {
            pathOnly = String(path[path.startIndex..<q])
        } else {
            pathOnly = path
        }

        guard pathOnly.hasPrefix("/") else {
            return .notFound
        }

        // Бьём по сырым '/'. Лидирующий '/' даёт пустой первый элемент — отбрасываем его.
        // Внутренние/хвостовые пустые сегменты (//, /album/X/) сохраняем — они значимы
        // для проверки traversal (пустой сегмент недопустим).
        var rawSegments = pathOnly.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // Первый элемент после ведущего '/' всегда пустой — убираем.
        if let first = rawSegments.first, first.isEmpty {
            rawSegments.removeFirst()
        } else {
            return .notFound
        }

        switch rawSegments.count {
        case 1:
            switch rawSegments[0] {
            case "manifest": return .manifest
            case "pair": return .pair
            case "confirm": return .confirm
            default: return .notFound
            }

        case 3 where rawSegments[0] == "album":
            // /album/<albumId>/<fileName>
            guard let albumId = safeDecode(rawSegments[1]),
                  let fileName = safeDecode(rawSegments[2]) else {
                return .notFound
            }
            return .album(id: albumId, fileName: fileName)

        default:
            return .notFound
        }
    }

    /// Percent-декодирует один сегмент пути и валидирует его на безопасность.
    /// Возвращает nil, если сегмент опасен (traversal) или нечитаем.
    private static func safeDecode(_ segment: String) -> String? {
        guard let decoded = segment.removingPercentEncoding else {
            // Битая percent-кодировка — отвергаем.
            return nil
        }

        // Пустой / из одних пробелов — недопустимо.
        if decoded.trimmingCharacters(in: .whitespaces).isEmpty {
            return nil
        }
        // Относительная навигация.
        if decoded == "." || decoded == ".." {
            return nil
        }
        // Декодированный '/' (из %2F) — фальшивый разделитель пути.
        if decoded.contains("/") {
            return nil
        }
        // Абсолютный путь.
        if decoded.hasPrefix("/") {
            return nil
        }
        // Нулевой байт — классический инъекционный обрыв строки.
        if decoded.unicodeScalars.contains(where: { $0 == "\u{0}" }) {
            return nil
        }

        return decoded
    }
}
