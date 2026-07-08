# Предложка v2: валидация, память, категории, «открыть в…»

Апгрейд AI-ленты «Главной» (поверх home-ai + ai-profiles): external-
рекомендации становятся полноценным discovery-сервисом. Лента остаётся
единой (карусели, как в Apple Music, без визуального разнобоя
источников), но под капотом: ротация категорий, валидация существования
через iTunes Search, память показанного + фидбек, ссылки «открыть в
Apple Music / Яндекс.Музыке / Bandcamp / YouTube», опциональный
скелет похожих артистов от Deezer.

## Диагноз (ресёрч 2026-07-07)

«Просто отправить историю в LLM» проседает по четырём причинам, и все
чинятся обвязкой, не заменой подхода:

| Проблема | Лечение |
|---|---|
| Галлюцинации (выдуманные альбомы, особенно в нишевом) | валидация каждого кандидата через iTunes Search (бесплатно, без ключа) + запас кандидатов ×1.5 |
| Повторяемость между запусками | память показанного в GRDB + список «уже предлагали» в промпт + клиентский дедуп |
| Уклон в канон (OK Computer everywhere) | анти-канон инструкции в нишевых категориях; в «Классике, которую пропустил» уклон работает на нас |
| Свежесть (cutoff модели) | категория «Свежие релизы» только при `webSearch=true` активного профиля (инфраструктура готова) |

Проверено живьём: iTunes Search отдаёт `collectionViewUrl` (готовая
ссылка Apple Music), обложку, жанр, год — из того же запроса, что и
валидация; Odesli (song.link) по Apple Music-URL возвращает прямую
ссылку `music.yandex.ru/album/…` (лимит 10/мин без ключа — только по
тапу); Deezer `artist/{id}/related` работает без ключа и даёт хорошие
результаты; Spotify recommendations API закрыт для новых приложений
(вычеркнут). Риск: доступность `api.deezer.com`/Odesli из RU-сети без
VPN не гарантирована — оба источника деградируют молча.

## Контракт ленты (ZverBrain)

Инвариант home-ai сохраняется: `HomeFeed` строго Codable, промпт
детерминирован, обновление только вручную, кэш `homefeed.json`.
Изменения аддитивные (старый кэш читается):

- `HomeSection` + `category: String?` — слаг категории для external-
  секций (эхо от модели; нужен ротации, фидбек-метрикам и UI).
- Новый `DiscoveryCategory: String, Codable, CaseIterable` — пул
  категорий с инструкциями для промпта:

| Слаг | Категория | Механика |
|---|---|---|
| `similar-to-obsession` | «Похоже на твоё последнее» | якорь — «одержимость» (альбом с аномальной плотностью прослушиваний за 14 дней) |
| `deeper-discography` | «Глубже в дискографию» | артисты ИЗ библиотеки, альбомы которых нет — почти нулевые галлюцинации |
| `missed-classics` | «Классика, которую ты пропустил» | канон в жанрах пользователя, отсутствующий в библиотеке |
| `dig-deeper` | «Копни глубже» | нишевое; анти-канон: «не из общеизвестных топов», строже валидируется |
| `fresh-releases` | «Свежие релизы для тебя» | только при webSearch: «ищи релизы последних недель в вебе, не из памяти» |
| `sideways` | «Совсем другое» | шаг вбок через общую нить (продюсер, лейбл, эпоха) с объяснением моста |
| `scene-dive` | «Сцена / лейбл» | «весь ранний Warp», «кентерберийская сцена» — текстовый граф LLM |
| `time-travel` | «Из другого времени» | те же вкусовые векторы, но декада, где пользователь не копался |

- `HomeFeedPrompt.build(snapshot:categories:customInstructions:)` —
  промпт остаётся детерминированным: **выбор категорий делает
  приложение** и передаёт параметром. External-секции = ровно заказанные
  категории, 4–6 кандидатов каждая (запас под отсев), `category`-эхо
  в JSON. Библиотечные `albums`-секции — без изменений.
- `LibrarySnapshot` + новые сигналы: `obsessions: [String]` (строки
  «Артист — Альбом»), `skippedArtists: [String]` (из
  `playEvent.endReason == 'skipped'` — уже пишется),
  `recFeedback: RecFeedback { liked, hidden, recentlyShown: [String] }`.
  Промпт-блоки: ОДЕРЖИМОСТИ, НЕ ЗАХОДИТ (скипы + hidden, «не предлагай
  похожее без веской причины»), ПОНРАВИЛОСЬ ИЗ РЕКОМЕНДАЦИЙ,
  УЖЕ ПРЕДЛАГАЛИ (жёсткий запрет повтора).
- `HomeFeedParser`: без изменений логики, external-секции несут
  `category` (отсутствует — терпим, секция живёт без слага).
- Deezer-скелет: `DeezerRelatedFetcher` в ZverBrain (пакет автономен,
  паттерн `ModelCatalogFetcher`): `search?q=<artist>` → id →
  `artist/{id}/related` → имена. Снапшот +
  `similarArtistsHints: [String: [String]]` (топ-5 артистов → до 10
  родственных) → промпт-блок «РОДСТВЕННЫЕ АРТИСТЫ (по данным
  слушателей Deezer)» с инструкцией «выбирай из них И добавляй
  неочевидное от себя». LLM остаётся куратором — в UI это не отдельная
  «дизер-секция», а подпись-кредит в subtitle секций, где скелет
  использовался. Ошибка сети → скелет молча пропускается.

## Память и фидбек (ZverCore)

Миграция **v7** в `Catalog.swift` (паттерн v6), таблица `recommendation`:
`id` autoincrement PK, `artist`, `album` TEXT NOT NULL, `normKey` TEXT
NOT NULL UNIQUE, `year` INTEGER, `category` TEXT, `reason` TEXT,
`status` TEXT NOT NULL ('shown'|'liked'|'hidden'|'owned'), `genre` TEXT,
`appleMusicURL` TEXT, `artworkURL` TEXT, `itunesId` INTEGER,
`links` TEXT (JSON-кэш Odesli), `shownAt`/`updatedAt` DATETIME NOT NULL.
Индекс по `shownAt`. Без FK (как favorite/playEvent).

- `ReleaseNorm.key(artist:album:)` (ZverCore, чистая): lowercase, срез
  диакритики, удаление пунктуации и издательских хвостов
  (`deluxe|remaster(ed)?|edition|anniversary|expanded|bonus|reissue`),
  схлопывание пробелов. Общая для дедупа и UNIQUE-ключа.
- `RecommendationStore: Sendable` (DAO-паттерн `PlayHistoryStore`):
  `recordShown(_:)` (upsert по normKey, повтор обновляет shownAt),
  `setStatus(normKey:status:)`, `feedback(likedLimit:hiddenLimit:
  shownWindow:) -> RecFeedback`, `shownKeys(since:) -> Set<String>`,
  `cacheLinks(normKey:json:)`. Прокидывается в `LibraryStore` как
  `favoriteStore`/`historyStore`, строится в `ContentView` на общем
  каталоге.

## Пайплайн refresh (HomeFeedService)

1. Ротация: `home.categoryRotation` в UserDefaults — round-robin окно
   по пулу; всегда включается `similar-to-obsession` (есть одержимость)
   и `deeper-discography`, +2–3 ротирующихся; `fresh-releases` — только
   при `profiles.config?.webSearch == true`. Итого 4–5 категорий.
2. Снапшот: как сейчас + одержимости (из `listeningStats` за 14 дней,
   ≥K прослушиваний), скипнутые артисты, `RecommendationStore.feedback`.
   Deezer-скелет (если включён тумблер) — с таймаутом 8с, ошибки тихие.
3. LLM → `HomeFeedParser.parse` (как сейчас).
4. **Валидация** через `ITunesCatalog` (новый actor, эволюция
   `ITunesArtworkFetcher`): `resolve(artist:album:) async ->
   ResolvedRelease?` (`itunesId, appleMusicURL, artworkURL600, genre,
   year, canonicalArtist/Album`). Fuzzy-матч: `ReleaseNorm`-нормализация
   обеих сторон, сравнение по включению. Кэш диск+память (включая
   негативный, TTL 30 дней) в `Caches/HomeArtwork` (переезжает в
   `Caches/ITunesCatalog`); троттлинг 3.5с — только на промахах кэша.
   Прогресс в существующий `statusBanner`: «Проверяю рекомендации…
   N/M». Не нашлось — кандидат отбрасывается (для `dig-deeper` —
   ожидаемо чаще, на то и запас ×1.5).
5. **Дедуп**: normKey против (а) всех альбомов библиотеки,
   (б) показанного за 90 дней (кроме liked — их можно вернуть в якорях,
   но не как новую рекомендацию), (в) внутри самой ленты. Обрезка до
   2–4 элементов на секцию.
6. Прошедшие — `recordShown`; `ExternalSuggestion` расширяется:
   `appleMusicURL, artworkURL, genre, category, normKey` (Codable,
   опциональные — старый `homefeed.json` читается). Карточки берут
   обложку по готовому `artworkURL` (быстрее и без второго похода
   в iTunes).

Замер стоимости: 5 секций × 6 кандидатов = 30 валидаций, при тёплом
кэше — секунды; холодный первый раз ≈ 1.5–2 мин с прогрессом —
приемлемо для ручного обновления.

## UI («Главная»)

- Карусели и стиль — как сейчас, external-карточка получает бейдж жанра
  и маленький ♥, если liked.
- `ExternalSuggestionSheet` v2: обложка, reason, жанр/год, ряд кнопок
  «Открыть в…»: **Apple Music** (прямой `appleMusicURL`),
  **Яндекс.Музыка**, **Bandcamp**, **YouTube** (мгновенные поисковые
  URL: `music.yandex.ru/search?text=…`, `bandcamp.com/search?q=…&
  item_type=a`, `youtube.com/results?search_query=… full album`).
  Действия: ♥ «Нравится», ✕ «Не моё» (секция перестаёт показывать,
  анти-сигнал в промпт), «У меня уже есть» (owned — страховка дедупа).
- Этап 2 — **Odesli по тапу**: при открытии шита один запрос
  `api.song.link/v1-alpha.1/links?url=<AM>&userCountry=RU` → точные
  ссылки Яндекс/Bandcamp/Tidal вместо поисковых, кэш в
  `recommendation.links`; лимит 10/мин не задевается (по тапу), таймаут
  → фоллбэк на поисковые URL.
- Этап 2 — мост к импорту: кнопка «Найти на Bandcamp» открывает
  Bandcamp-экран вкладки «Импорт» с поисковым URL (петля: рекомендация
  → $0/покупка → FLAC в библиотеке → сигнал owned).
- Тумблер «Похожие артисты (Deezer)» — секция ИИ в настройках,
  `@AppStorage("brain.deezerHints")`, по умолчанию вкл, футер про
  «данные слушателей Deezer в подсказках модели».

## План внедрения

1. **ZverCore v7 + RecommendationStore + ReleaseNorm.** Миграция,
   DAO, нормализация. Тесты на in-memory GRDB (upsert, статусы,
   feedback-выборки, normKey-краевые: диакритика, Deluxe).
2. **ZverBrain: категории + сигналы + промпт.** `DiscoveryCategory`,
   `build(snapshot:categories:…)`, новые блоки снапшота,
   `HomeSection.category`. Тесты промпта (блоки, инструкции категорий,
   детерминизм) и парсера (category-эхо, обратная совместимость).
3. **ITunesCatalog + пайплайн валидации/дедупа в HomeFeedService.**
   Resolve с fuzzy-матчем (чистая функция — юнит-тесты), троттлинг,
   кэш, прогресс в баннер, recordShown, расширение
   `ExternalSuggestion`/кэша ленты.
4. **UI фидбека и ссылок.** Шит v2 (кнопки «Открыть в…» на поисковых
   URL + прямой Apple Music), ♥/✕/«уже есть», ротация категорий.
   Ручная проверка ленты end-to-end.
5. **Deezer-скелет.** `DeezerRelatedFetcher` (тесты на MockURLProtocol),
   тумблер, промпт-блок, кредит в subtitle.
6. **Odesli по тапу + «Найти на Bandcamp»-мост** (после фичи импорта).

Каждый пункт — отдельный коммит с зелёными
`swift test --package-path Packages/{ZverCore,ZverBrain}` и сборкой iOS.

## Верификация

- Пакетные тесты: миграция v7, RecommendationStore, ReleaseNorm,
  промпт/парсер с категориями, DeezerRelatedFetcher и iTunes-разбор на
  MockURLProtocol (эндпоинты, троттлинг не тестируем таймерами —
  выносим политику в чистую функцию).
- Руками: обновление ленты с профилем без webSearch (нет «Свежих
  релизов») и с ним; скрытие рекомендации → не возвращается после
  следующего refresh; «уже есть» на альбоме из библиотеки, добытом
  переименованием (Deluxe); все четыре кнопки «Открыть в…» на реальном
  альбоме; выключенный Deezer-тумблер / недоступная сеть Deezer —
  лента строится без скелета; старый `homefeed.json` читается после
  обновления приложения.
