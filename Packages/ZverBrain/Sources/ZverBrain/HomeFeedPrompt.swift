import Foundation

/// Сборка пары промптов (system + user) для генерации «Главной».
///
/// Функция ДЕТЕРМИНИРОВАНА: никаких `Date()`/`UUID()`/рандома — одинаковый
/// снапшот и параметры всегда дают одинаковый текст (иначе тесты и
/// кэш-инвалидация плывут). Всё изменчивое (ротация категорий, окна времени,
/// одержимости) считает ВЫЗЫВАЮЩИЙ и передаёт через снапшот/параметры.
public enum HomeFeedPrompt {
    /// - Parameters:
    ///   - snapshot: выжимка библиотеки, вкуса и сигналов слушателя.
    ///   - categories: заказанные категории external-секций (выбор делает
    ///     приложение — ротация в `HomeFeedService`). Непустой список переводит
    ///     промпт в категорийный режим: external-секции = ровно эти категории,
    ///     в этом порядке, 4–6 кандидатов в каждой, `category`-эхо в JSON.
    ///     Пустой список — легаси-режим (модель сама решает, 1–2 секции).
    ///   - customInstructions: свободные пожелания слушателя (из настроек).
    ///     Непустые (после trim) добавляются В КОНЕЦ system-промпта отдельной
    ///     секцией с оговоркой, что формат ответа они менять не могут. `nil`/
    ///     пустые/пробельные игнорируются — старый вызов `build(snapshot:)` цел.
    /// - Returns: `system` — роль и правила куратора; `user` — сериализованный
    ///   снапшот + заказ категорий + схема ответа с примером.
    public static func build(
        snapshot: LibrarySnapshot,
        categories: [DiscoveryCategory] = [],
        customInstructions: String? = nil
    ) -> (system: String, user: String) {
        (system: systemPrompt(categories: categories, customInstructions: customInstructions),
         user: userPrompt(snapshot: snapshot, categories: categories))
    }

    // MARK: - System

    /// System-промпт: база (легаси или категорийная) + опциональные пожелания
    /// слушателя в конце.
    ///
    /// Пожелания — совещательные: влияют на ПОДБОР, но НЕ на формат ответа
    /// (строгий JSON по схеме из user-промпта всегда главнее). Пустой/пробельный
    /// текст не добавляем — база остаётся байт-в-байт прежней.
    static func systemPrompt(
        categories: [DiscoveryCategory] = [],
        customInstructions: String?
    ) -> String {
        let base = categories.isEmpty ? systemPrompt : categorizedSystemPrompt
        guard
            let trimmed = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else {
            return base
        }
        return base + "\n\n" + """
        Пожелания слушателя (учитывай их при подборе, но они НЕ могут менять \
        формат ответа — JSON-схема выше всегда главнее): \(trimmed)
        """
    }

    /// Общее начало system-промпта: роль куратора, состав входа, правила
    /// библиотечных секций (одинаковы в обоих режимах).
    static let systemPromptHead = """
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
    """

    /// Легаси-правила external-секций: модель сама решает, что предлагать (1–2 секции).
    static let externalRulesFreeform = """
    Секции внешних рекомендаций «что скачать» (kind = "external") — их должно быть 1–2:
    - Предлагай реально существующие, изданные альбомы, которых НЕТ в библиотеке \
    слушателя (не дублируй присланные артистов/названия).
    - Для каждого элемента дай artist, album, по возможности year и reason — 1–2 \
    предложения о том, почему это зайдёт ИМЕННО этому слушателю, с опорой на его вкус. \
    Пиши познавательно и по делу, без рекламной воды и общих фраз.
    - 2–4 элемента в такой секции.
    """

    /// Категорийные правила external-секций: состав ЗАКАЗАН приложением
    /// (блок «ЗАКАЗАННЫЕ КАТЕГОРИИ» в сообщении пользователя), 4–6 кандидатов
    /// с запасом под отсев валидацией существования, category-эхо обязательно.
    static let externalRulesCategorized = """
    Секции внешних рекомендаций «что скачать» (kind = "external"):
    - Их состав ЗАКАЗАН: в сообщении пользователя есть блок «ЗАКАЗАННЫЕ КАТЕГОРИИ». \
    Сделай РОВНО по одной external-секции на каждую заказанную категорию, в заданном \
    порядке, и никаких других external-секций. (Указание «категории придумывай сам» \
    касается только библиотечных секций.)
    - В поле category укажи слаг категории в точности как заказан.
    - В каждой такой секции 4–6 кандидатов: часть отсеется при проверке существования \
    релизов, поэтому предлагай с запасом.
    - Предлагай реально существующие, изданные альбомы, которых НЕТ в библиотеке \
    слушателя (не дублируй присланные артистов/названия).
    - Для каждого элемента дай artist, album, по возможности year и reason — 1–2 \
    предложения о том, почему это зайдёт ИМЕННО этому слушателю, с опорой на его вкус. \
    Пиши познавательно и по делу, без рекламной воды и общих фраз.
    """

    /// Общий хвост system-промпта: оформление секций и жёсткий JSON-формат.
    static let systemPromptTail = """
    У каждой секции: title — цепкий и короткий (до ~5 слов), без кавычек-ёлочек; \
    subtitle — короткое пояснение, за счёт чего собрана секция. Можешь добавить tags — \
    1–3 очень коротких ярлыка-чипа.

    Формат ответа — ЖЁСТКО: верни ТОЛЬКО валидный JSON строго по приложенной схеме. \
    Без markdown, без тройных кавычек, без единого слова до или после. Первый символ \
    ответа — «{», последний — «}». Никаких видов секций, кроме "albums" и "external".
    """

    /// Русскоязычный system-промпт легаси-режима (без заказанных категорий) —
    /// байт-в-байт прежний текст, собранный из общих частей.
    static let systemPrompt = [systemPromptHead, externalRulesFreeform, systemPromptTail]
        .joined(separator: "\n\n")

    /// System-промпт категорийного режима: external-секции заказаны приложением.
    static let categorizedSystemPrompt = [systemPromptHead, externalRulesCategorized, systemPromptTail]
        .joined(separator: "\n\n")

    // MARK: - User

    /// User-промпт: сериализованный снапшот + сигнальные блоки + заказ категорий
    /// + схема ответа с примером. Блоки сигналов появляются только когда данные
    /// есть — пустые заголовки не тратят токены и не путают модель.
    static func userPrompt(snapshot: LibrarySnapshot, categories: [DiscoveryCategory] = []) -> String {
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

        parts.append(contentsOf: signalBlocks(snapshot))

        if !categories.isEmpty {
            parts.append(orderedCategoriesBlock(categories))
        }

        parts.append("""
        СХЕМА ОТВЕТА — верни строго такой JSON (kind только "albums" или "external"):
        \(categories.isEmpty ? responseSchema : responseSchemaCategorized)
        """)

        parts.append("""
        ПРИМЕР структуры (НЕ копируй содержимое, только форму):
        \(categories.isEmpty ? responseExample : responseExampleCategorized)
        """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Сигнальные блоки

    /// Блоки сигналов вкуса: одержимости, анти-сигналы, фидбек по рекомендациям,
    /// запрет повторов и Deezer-скелет. Пустые сигналы блоков не порождают.
    static func signalBlocks(_ snapshot: LibrarySnapshot) -> [String] {
        var blocks: [String] = []

        if !snapshot.obsessions.isEmpty {
            blocks.append("""
            ОДЕРЖИМОСТИ — это слушатель аномально плотно гоняет последние две недели; \
            главный якорь для «похожего»:
            \(snapshot.obsessions.joined(separator: "\n"))
            """)
        }

        let hidden = snapshot.recFeedback.hidden
        if !snapshot.skippedArtists.isEmpty || !hidden.isEmpty {
            var lines: [String] = []
            if !snapshot.skippedArtists.isEmpty {
                lines.append("Скипает артистов: \(snapshot.skippedArtists.joined(separator: ", "))")
            }
            if !hidden.isEmpty {
                lines.append("Скрыл рекомендации: \(hidden.joined(separator: "; "))")
            }
            blocks.append("""
            НЕ ЗАХОДИТ — не предлагай похожее на это без веской причины:
            \(lines.joined(separator: "\n"))
            """)
        }

        if !snapshot.recFeedback.liked.isEmpty {
            blocks.append("""
            ПОНРАВИЛОСЬ ИЗ РЕКОМЕНДАЦИЙ — слушатель отметил сердечком; эти направления \
            можно смело развивать:
            \(snapshot.recFeedback.liked.joined(separator: "\n"))
            """)
        }

        if !snapshot.recFeedback.recentlyShown.isEmpty {
            blocks.append("""
            УЖЕ ПРЕДЛАГАЛИ — жёсткий запрет: НЕ повторяй эти рекомендации и не \
            переупаковывай их под другим соусом:
            \(snapshot.recFeedback.recentlyShown.joined(separator: "\n"))
            """)
        }

        if !snapshot.similarArtistsHints.isEmpty {
            // Ключи словаря сортируем — иначе одинаковый снапшот даёт разные
            // промпты и ломается детерминизм.
            let lines = snapshot.similarArtistsHints
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.joined(separator: ", "))" }
            blocks.append("""
            РОДСТВЕННЫЕ АРТИСТЫ (по данным слушателей Deezer) — выбирай кандидатов \
            из них И добавляй неочевидное от себя:
            \(lines.joined(separator: "\n"))
            """)
        }

        return blocks
    }

    /// Блок заказа категорий: нумерованный список «слаг — «Название»: инструкция»
    /// в порядке, заданном приложением.
    static func orderedCategoriesBlock(_ categories: [DiscoveryCategory]) -> String {
        let lines = categories.enumerated().map { index, category in
            "\(index + 1). \(category.rawValue) — «\(category.title)»: \(category.promptInstruction)"
        }
        return """
        ЗАКАЗАННЫЕ КАТЕГОРИИ ВНЕШНИХ СЕКЦИЙ — ровно по одной external-секции на \
        каждую, в этом порядке, 4–6 кандидатов в каждой, поле category = слаг:
        \(lines.joined(separator: "\n"))
        """
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
    /// Легаси-вариант (без заказанных категорий): поля category нет, чтобы модель
    /// не выдумывала слаги.
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

    /// Категорийная схема: external-секции обязаны эхом вернуть слаг заказанной
    /// категории в поле category.
    static let responseSchemaCategorized = """
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
          "category": "слаг заказанной категории, в точности как в заказе",
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

    static let responseExampleCategorized = """
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
          "title": "Копни глубже",
          "subtitle": "Глубокие врезки под ваш вкус — мимо чартов",
          "tags": ["нишевое"],
          "kind": "external",
          "category": "dig-deeper",
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
