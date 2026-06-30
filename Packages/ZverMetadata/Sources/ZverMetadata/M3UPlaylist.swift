import Foundation

/// Чистый разбор плейлиста `.m3u`/`.m3u8`: задаёт ПОРЯДОК треков в папке альбома.
///
/// Многие рипы (особенно винил-LP) кладут рядом `Playlist.m3u`, где перечислены
/// файлы треков в нужном порядке — а теги `TRACKNUMBER` при этом нечисловые
/// (виниловые «A1», «B2», …) и сортировка по ним не работает. Сканер при наличии
/// плейлиста проставляет трекам порядковый номер из него.
///
/// Формат прост: одна ссылка на файл в строке. Строки, начинающиеся с `#`
/// (директивы `#EXTM3U`/`#EXTINF`, комментарии), и пустые — игнорируются. Ссылка
/// может быть относительным путём (в т.ч. с обратным слэшем Windows) — берём имя
/// файла (последний компонент пути). Поддержан UTF-8 BOM в начале файла.
///
/// Только разбор строки, без ФС — поэтому покрыт юнит-тестами на литералах;
/// чтение файла и сопоставление с аудио — в ``LibraryScanner``.
public enum M3UPlaylist {
    /// Имена файлов из плейлиста (последний компонент пути) в порядке плейлиста.
    /// Комментарии/директивы (`#…`) и пустые строки пропущены.
    public static func entries(from content: String) -> [String] {
        var stripped = content
        if stripped.hasPrefix("\u{FEFF}") {
            stripped.removeFirst()
        }
        var result: [String] = []
        // `\r\n` — единый grapheme cluster в Swift и НЕ равен Character "\n", поэтому
        // split по "\n" не разбил бы CRLF-файл. `isNewline` ловит \n, \r и \r\n.
        for rawLine in stripped.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            result.append(lastPathComponent(line))
        }
        return result
    }

    /// Карта `имя файла (нижний регистр)` → `1-based позиция` в плейлисте.
    /// При повторе имени побеждает ПЕРВОЕ вхождение.
    public static func order(from content: String) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, name) in entries(from: content).enumerated() {
            let key = name.lowercased()
            if map[key] == nil {
                map[key] = index + 1
            }
        }
        return map
    }

    /// Последний компонент пути по разделителям `/` и `\` (Windows-ссылки).
    private static func lastPathComponent(_ reference: String) -> String {
        let parts = reference.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.last.map(String.init) ?? reference
    }
}
