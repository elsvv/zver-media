import Foundation

/// Чистый разбор плейлиста `.m3u`/`.m3u8`: задаёт ПОРЯДОК треков и (если ссылки —
/// вложенные пути `CD1/…`, `Side A/…`) деление альбома на ДИСКИ/СТОРОНЫ.
///
/// Многие рипы кладут в корень альбома `playlist.m3u8`, где перечислены файлы
/// треков относительными путями через подпапки-диски. Тег `DISCNUMBER` при этом
/// может отсутствовать вовсе (как у ремастеров-боксов), а `TRACKNUMBER`
/// перезапускается на каждом диске — поэтому плейлист и есть главный источник
/// структуры. Сканер при наличии плейлиста берёт из него порядок и метки дисков.
///
/// Формат прост: одна ссылка на файл в строке. Строки, начинающиеся с `#`
/// (`#EXTM3U`/`#EXTINF`, комментарии), и пустые — игнорируются. Ссылка может быть
/// относительным путём (в т.ч. с обратным слэшем Windows). Поддержан UTF-8 BOM.
///
/// Только разбор строки, без ФС — покрыт юнит-тестами на литералах; чтение файла
/// и сопоставление с аудио — в ``LibraryScanner``.
public enum M3UPlaylist {
    /// Запись плейлиста: нормализованный относительный путь, имя файла и метка
    /// диска (ближайшая родительская папка, если ссылка вложенная; иначе nil).
    public struct Entry: Equatable, Sendable {
        public let path: String       // нормализованный путь, разделитель '/'
        public let fileName: String   // последний компонент пути
        public let disc: String?      // папка-диск (nil, если файл в корне альбома)
    }

    /// Позиция трека в структуре плейлиста: метка и порядок диска + позиция внутри
    /// диска и во всём плейлисте.
    public struct DiscInfo: Equatable, Sendable {
        public let discLabel: String?   // метка диска для UI (nil = один диск/корень)
        public let discOrdinal: Int     // 1-based порядок диска по первому появлению
        public let position: Int        // 1-based позиция трека ВНУТРИ диска
        public let globalPosition: Int  // 1-based позиция во всём плейлисте
    }

    /// Разбор плейлиста в записи (в порядке файла), с относительным путём и диском.
    public static func parse(from content: String) -> [Entry] {
        var stripped = content
        if stripped.hasPrefix("\u{FEFF}") {
            stripped.removeFirst()
        }
        var result: [Entry] = []
        // `\r\n` — единый grapheme cluster в Swift и НЕ равен Character "\n", поэтому
        // split по "\n" не разбил бы CRLF-файл. `isNewline` ловит \n, \r и \r\n.
        for rawLine in stripped.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            result.append(makeEntry(line))
        }
        return result
    }

    /// Имена файлов из плейлиста (последний компонент пути) в порядке плейлиста.
    public static func entries(from content: String) -> [String] {
        parse(from: content).map(\.fileName)
    }

    /// Карта `имя файла (нижний регистр)` → `1-based позиция` в плейлисте.
    /// При повторе имени побеждает ПЕРВОЕ вхождение. (Плоские альбомы: сопоставление
    /// по имени файла; для вложенных дисков используйте ``discMap(from:)``.)
    public static func order(from content: String) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, entry) in parse(from: content).enumerated() {
            let key = entry.fileName.lowercased()
            if map[key] == nil {
                map[key] = index + 1
            }
        }
        return map
    }

    /// Карта `нормализованный относительный путь (нижний регистр)` → ``DiscInfo``.
    /// Порядок диска — по первому появлению его папки; позиция — внутри диска.
    /// Записи в корне (без папки) получают `discLabel == nil` и группируются как
    /// единый «диск». При повторе пути побеждает ПЕРВОЕ вхождение.
    public static func discMap(from content: String) -> [String: DiscInfo] {
        var map: [String: DiscInfo] = [:]
        var discOrdinals: [String: Int] = [:]   // ключ папки-диска ("" — корень)
        var counts: [String: Int] = [:]          // треков уже в диске
        var nextOrdinal = 1
        for (index, entry) in parse(from: content).enumerated() {
            let discKey = entry.disc ?? ""
            if discOrdinals[discKey] == nil {
                discOrdinals[discKey] = nextOrdinal
                nextOrdinal += 1
            }
            let ordinal = discOrdinals[discKey] ?? nextOrdinal
            let pos = (counts[discKey] ?? 0) + 1
            counts[discKey] = pos
            let key = entry.path.lowercased()
            if map[key] == nil {
                map[key] = DiscInfo(discLabel: entry.disc,
                                    discOrdinal: ordinal,
                                    position: pos,
                                    globalPosition: index + 1)
            }
        }
        return map
    }

    /// Нормализует ссылку: разделитель `/`, срезает ведущее `./`. Метка диска —
    /// ближайшая родительская папка (для `CD1/01.flac` → `CD1`); для файла в корне
    /// альбома папки нет → nil.
    private static func makeEntry(_ reference: String) -> Entry {
        var norm = reference.replacingOccurrences(of: "\\", with: "/")
        while norm.hasPrefix("./") { norm.removeFirst(2) }
        let segments = norm.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let fileName = segments.last ?? norm
        let disc = segments.count >= 2 ? segments[segments.count - 2] : nil
        let path = segments.isEmpty ? norm : segments.joined(separator: "/")
        return Entry(path: path, fileName: fileName, disc: disc)
    }
}
