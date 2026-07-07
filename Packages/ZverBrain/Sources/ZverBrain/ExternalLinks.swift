import Foundation

/// Мгновенные поисковые URL «Открыть в…» для внешних рекомендаций (шит v2).
///
/// Прямая ссылка есть только у Apple Music (`collectionViewUrl` из валидации);
/// остальные сервисы открываются поиском — без сети и ключей, работает всегда.
/// Точные ссылки Яндекс/Bandcamp через Odesli — этап 2 (по тапу, с кэшем).
/// Функции чистые: пара «артист + альбом» → URL, ничего больше.
public enum ExternalLinks {
    /// Поиск релиза в Яндекс.Музыке: `music.yandex.ru/search?text=…`.
    public static func yandexMusic(artist: String, album: String) -> URL {
        url(host: "music.yandex.ru", path: "/search",
            query: [.init(name: "text", value: "\(artist) \(album)")])
    }

    /// Поиск релиза на Bandcamp: `item_type=a` сужает выдачу до альбомов.
    public static func bandcamp(artist: String, album: String) -> URL {
        url(host: "bandcamp.com", path: "/search",
            query: [.init(name: "q", value: "\(artist) \(album)"),
                    .init(name: "item_type", value: "a")])
    }

    /// Поиск на YouTube: хвост «full album» выводит полные альбомы вперёд.
    public static func youtube(artist: String, album: String) -> URL {
        url(host: "www.youtube.com", path: "/results",
            query: [.init(name: "search_query", value: "\(artist) \(album) full album")])
    }

    /// Сборка через URLComponents — правильное percent-экранирование значений
    /// (включая `&`/`=` внутри). Схема и хост валидны по построению, поэтому
    /// `url` не может быть nil — force unwrap безопасен.
    private static func url(host: String, path: String,
                            query: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query
        return components.url!
    }
}
