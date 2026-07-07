import Foundation

/// Сборка пары промптов (system + user) для генерации «Главной».
///
/// Функция ДЕТЕРМИНИРОВАНА: никаких `Date()`/`UUID()`/рандома — одинаковый
/// снапшот всегда даёт одинаковый текст (иначе тесты и кэш-инвалидация плывут).
public enum HomeFeedPrompt {
    /// - Parameters:
    ///   - snapshot: выжимка библиотеки и вкуса слушателя.
    ///   - customInstructions: свободные пожелания слушателя (из настроек).
    ///     Непустые (после trim) добавляются В КОНЕЦ system-промпта отдельной
    ///     секцией с оговоркой, что формат ответа они менять не могут. `nil`/
    ///     пустые/пробельные игнорируются — старый вызов `build(snapshot:)` цел.
    /// - Returns: `system` — роль и правила куратора; `user` — сериализованный
    ///   снапшот + схема ответа с примером.
    public static func build(
        snapshot: LibrarySnapshot,
        customInstructions: String? = nil
    ) -> (system: String, user: String) {
        (system: systemPrompt(customInstructions: customInstructions),
         user: userPrompt(snapshot: snapshot))
    }

    // MARK: - System

    /// System-промпт с опциональными пожеланиями слушателя в конце.
    ///
    /// Пожелания — совещательные: влияют на ПОДБОР, но НЕ на формат ответа
    /// (строгий JSON по схеме из user-промпта всегда главнее). Пустой/пробельный
    /// текст не добавляем — база остаётся байт-в-байт прежней.
    static func systemPrompt(customInstructions: String?) -> String {
        guard
            let trimmed = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return systemPrompt
        }
        return systemPrompt + "\n\n" + """
        Пожелания слушателя (учитывай их при подборе, но они НЕ могут менять \
        формат ответа — JSON-схема выше всегда главнее): \(trimmed)
        """
    }

    /// Русскоязычный system-промпт: роль музыкального куратора + жёсткие правила
    /// (счёт секций, «только id из списка», внешние секции, строгий JSON).
    static let systemPrompt = """
    Ты — музыкальный куратор персональной lossless-библиотеки одного слушателя. \
    Твоя задача — собрать экран «Главная»: живую редакторскую витрину подборок по \
    его фонотеке и вкусу, а не сухой список «топ по количеству прослушиваний».

    Что тебе дают в сообщении пользователя: список альбомов библиотеки (у каждого \
    стабильный короткий id вида A17), топ-артистов и топ-альбомов по числу \
    прослушиваний, избранные альбомы, любимые треки, недавно добавленное и недавно \
    прослушанное. Жанров и тегов НЕТ — характер и настроение музыки выводи сам из \
    имён артистов и названий альбомов.

    Собери от 5 до 8 секций. Категории придумывай сам — разнообразные и небанальные. \
    Комбинируй ракурсы: настроение и время суток («для позднего вечера»), декада или \
    эпоха звучания, невидимая нить между артистами (общий продюсер, лейбл, сцена, \
    родство звучания), «глубокие врезки» — сильные, но недооценённые альбомы из его \
    же библиотеки, редкие или пограничные жанры, неожиданные контрасты. Избегай \
    очевидного вроде «Ваши любимые» или «Часто слушаете» — это скучно.

    Секции из библиотеки (kind = "albums"):
    - В поле albumIds указывай ТОЛЬКО id из присланного списка. НЕ выдумывай id и НЕ \
    изобретай альбомы, которых нет в списке. Любой id не из списка будет отброшен, а \
    секция может стать пустой и исчезнуть.
    - 3–8 альбомов в секции. Не тащи один и тот же альбом в каждую секцию.

    Секции внешних рекомендаций «что скачать» (kind = "external") — их должно быть 1–2:
    - Предлагай реально существующие, изданные альбомы, которых НЕТ в библиотеке \
    слушателя (не дублируй присланные артистов/названия).
    - Для каждого элемента дай artist, album, по возможности year и reason — 1–2 \
    предложения о том, почему это зайдёт ИМЕННО этому слушателю, с опорой на его вкус. \
    Пиши познавательно и по делу, без рекламной воды и общих фраз.
    - 2–4 элемента в такой секции.

    У каждой секции: title — цепкий и короткий (до ~5 слов), без кавычек-ёлочек; \
    subtitle — короткое пояснение, за счёт чего собрана секция. Можешь добавить tags — \
    1–3 очень коротких ярлыка-чипа.

    Формат ответа — ЖЁСТКО: верни ТОЛЬКО валидный JSON строго по приложенной схеме. \
    Без markdown, без тройных кавычек, без единого слова до или после. Первый символ \
    ответа — «{», последний — «}». Никаких видов секций, кроме "albums" и "external".
    """

    // MARK: - User

    /// User-промпт: сериализованный снапшот + схема ответа с примером.
    static func userPrompt(snapshot: LibrarySnapshot) -> String {
        var parts: [String] = []

        parts.append("""
        БИБЛИОТЕКА — используй только эти id (формат «id: артист — альбом (год)»):
        \(albumsBlock(snapshot.albums))
        """)

        parts.append("""
        ТОП-АРТИСТЫ (имя × прослушиваний):
        \(topArtistsBlock(snapshot.topArtists))
        """)

        parts.append("""
        ТОП-АЛЬБОМЫ (id × прослушиваний):
        \(topAlbumsBlock(snapshot.topAlbums))
        """)

        parts.append("ИЗБРАННЫЕ АЛЬБОМЫ: \(idList(snapshot.favoriteAlbumIds))")
        parts.append("ЛЮБИМЫЕ ТРЕКИ: \(titleList(snapshot.favoriteTrackTitles))")
        parts.append("НЕДАВНО ПРОСЛУШАННОЕ: \(idList(snapshot.recentlyPlayedIds))")
        parts.append("НЕДАВНО ДОБАВЛЕННОЕ: \(idList(snapshot.recentlyAddedIds))")

        parts.append("""
        СХЕМА ОТВЕТА — верни строго такой JSON (kind только "albums" или "external"):
        \(responseSchema)
        """)

        parts.append("""
        ПРИМЕР структуры (НЕ копируй содержимое, только форму):
        \(responseExample)
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Сериализация блоков

    /// Строка одного альбома: `A17: Артист — Название (2003)`.
    /// Артист/год опускаются, если их нет (сборник / неизвестен).
    static func albumLine(_ entry: LibrarySnapshot.AlbumEntry) -> String {
        var line = "\(entry.id): "
        if let artist = entry.artist, !artist.isEmpty {
            line += "\(artist) — \(entry.album)"
        } else {
            line += entry.album
        }
        if let year = entry.year {
            line += " (\(year))"
        }
        return line
    }

    private static func albumsBlock(_ albums: [LibrarySnapshot.AlbumEntry]) -> String {
        guard !albums.isEmpty else { return "(библиотека пуста)" }
        return albums.map(albumLine).joined(separator: "\n")
    }

    private static func topArtistsBlock(_ artists: [LibrarySnapshot.ArtistPlays]) -> String {
        guard !artists.isEmpty else { return "—" }
        return artists.map { "\($0.name) (\($0.plays))" }.joined(separator: ", ")
    }

    private static func topAlbumsBlock(_ albums: [LibrarySnapshot.AlbumPlays]) -> String {
        guard !albums.isEmpty else { return "—" }
        return albums.map { "\($0.id) (\($0.plays))" }.joined(separator: ", ")
    }

    private static func idList(_ ids: [String]) -> String {
        ids.isEmpty ? "—" : ids.joined(separator: ", ")
    }

    private static func titleList(_ titles: [String]) -> String {
        titles.isEmpty ? "—" : titles.joined(separator: ", ")
    }

    // MARK: - Схема ответа

    /// Схема ожидаемого JSON — держим синхронной с ``HomeFeed``/``HomeSection``.
    static let responseSchema = """
    {
      "sections": [
        {
          "title": "строка, цепкий короткий заголовок",
          "subtitle": "строка или null — пояснение",
          "tags": ["строка", ...] | null,
          "kind": "albums",
          "albumIds": ["A1", "A2", ...]
        },
        {
          "title": "строка",
          "subtitle": "строка или null",
          "tags": ["строка", ...] | null,
          "kind": "external",
          "items": [
            { "artist": "строка", "album": "строка", "year": 1999 | null, "reason": "строка" }
          ]
        }
      ]
    }
    """

    static let responseExample = """
    {
      "sections": [
        {
          "title": "Для позднего вечера",
          "subtitle": "Медленный, обволакивающий звук в тёмных тонах",
          "tags": ["ночь", "эмбиент"],
          "kind": "albums",
          "albumIds": ["A3", "A11", "A7"]
        },
        {
          "title": "Скачать бы",
          "subtitle": "Соседние вселенные к тому, что вы уже любите",
          "tags": ["новое"],
          "kind": "external",
          "items": [
            {
              "artist": "Артист",
              "album": "Альбом",
              "year": 2004,
              "reason": "Одно-два предложения, почему это ляжет к вашему вкусу."
            }
          ]
        }
      ]
    }
    """
}
