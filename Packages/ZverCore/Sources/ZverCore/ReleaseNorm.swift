import Foundation

/// Чистая нормализация пары «артист + альбом» в устойчивый ключ релиза.
///
/// Один и тот же релиз приходит в разных написаниях: из тегов библиотеки,
/// от LLM, из iTunes Search («Sigur Rós» / «Sigur Ros», «OK Computer» /
/// «OK Computer (Deluxe Edition)»). Ключ объединяет варианты — он общий для
/// клиентского дедупа рекомендаций и UNIQUE-колонки `recommendation.normKey`
/// (миграция v7). Та же идея, что `ArtistName.key`, но жёстче: диакритика,
/// пунктуация и издательские хвосты альбома тоже срезаются.
public enum ReleaseNorm {
    /// Ключ релиза: `<артист>|<альбом>`. Обе части — lowercase, без диакритики,
    /// без пунктуации, с одиночными пробелами; у альбома дополнительно срезаны
    /// издательские хвосты (`deluxe|remaster(ed)?|edition|anniversary|expanded|
    /// bonus|reissue`). Разделитель `|` однозначен: пунктуация в частях удалена.
    public static func key(artist: String, album: String) -> String {
        normalize(artist) + "|" + strippingEditionTails(normalize(album))
    }

    /// Fuzzy-матч двух написаний релиза (кандидат LLM против находки iTunes).
    ///
    /// Чистая функция валидации «Предложки v2»: обе стороны нормализуются как
    /// в ``key(artist:album:)``, части сравниваются ПО ВКЛЮЧЕНИЮ — расширенное
    /// переиздание («OK Computer OKNOTOK 1997 2017») или приписка «feat. …» у
    /// артиста не рушат матч. Пустая нормализованная часть (артист «!!!»)
    /// матчится только с такой же пустой — включение на пустой строке дало бы
    /// матч с кем угодно.
    public static func fuzzyMatches(artist: String, album: String,
                                    otherArtist: String, otherAlbum: String) -> Bool {
        partMatches(normalize(artist), normalize(otherArtist))
            && partMatches(strippingEditionTails(normalize(album)),
                           strippingEditionTails(normalize(otherAlbum)))
    }

    /// Матч одной нормализованной части: равенство ИЛИ включение непустых.
    private static func partMatches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    // MARK: - Внутренности

    /// lowercase + срез диакритики + удаление пунктуации + схлопывание пробелов.
    ///
    /// Пунктуация удаляется БЕЗ следа (не заменяется пробелом): «R.E.M.» → «rem»,
    /// «AC/DC» → «acdc» — так аббревиатуры с точками и без дают один ключ.
    /// Границы слов сохраняют только пробельные символы оригинала.
    private static func normalize(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            }
            // прочее (пунктуация, символы) — удаляется без следа
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Издательские хвосты названий альбомов (уже нормализованные слова).
    /// «remastered» — отдельным словом, а не regex-опцией: сравниваем по словам.
    private static let editionTails: Set<Substring> = [
        "deluxe", "remaster", "remastered", "edition", "anniversary",
        "expanded", "bonus", "reissue",
    ]

    /// Срезает хвостовые издательские слова с УЖЕ нормализованного названия:
    /// «ok computer deluxe edition» → «ok computer». Только с конца — в середине
    /// названия эти слова легитимны («bonus round time»). Название, целиком
    /// состоящее из одного хвостового слова, не трогаем (альбом «Deluxe»).
    private static func strippingEditionTails(_ normalizedAlbum: String) -> String {
        var words = normalizedAlbum.split(separator: " ")
        while words.count > 1, let last = words.last, editionTails.contains(last) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }
}
