# Zver Cloud — Этап 2 «Каталог и библиотека»: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: исполнение через dynamic workflow (конвейер имплементер → спек-ревью ∥ код-ревью → фикс-луп), параллельные цепочки по графу зависимостей.

**Goal:** Персистентный каталог (GRDB) вместо рескана при каждом запуске, экраны артистов/альбомов/поиска, плейлисты, gapless-воспроизведение, фоллбэки импорта (обложка из folder.jpg, альбом из имени папки) и полиш по бэклогу ревью этапа 1.

**Architecture:** Каталог — GRDB в `ZverCore` (новая зависимость), хранит треки относительными путями от Documents (переживает реинсталл, у контейнера меняется UUID) + плейлисты. Альбомы по-прежнему вычисляются существующей группировкой. LibraryStore читает каталог мгновенно при старте, рескан — фоновая сверка (upsert + удаление пропавших). Gapless — предпланирование следующего трека той же частоты в AVAudioPlayerNode.

**Tech Stack:** + GRDB.swift 7.x (единственная новая зависимость).

**Контекст:** дизайн — `docs/plans/2026-06-06-zver-cloud-design.md`; этап 1 завершён (см. `2026-06-06-stage1-player-core.md`). Реальные данные пользователя: папки-раздачи вида `Radiohead - In Rainbows (2007) [24-44.1 WEB FLAC]/` с `folder.jpg` внутри.

**Граф исполнения:**

```
Параллельно:
├─ P (ZverCore):      S2-1 GRDB схема → S2-2 CatalogStore → S2-3 Плейлисты
├─ M (ZverMetadata):  S2-4 альбом из имени папки → S2-5 обложка из folder.jpg
└─ E (PlayerEngine):  S2-10 Gapless
Затем последовательно (общие файлы приложения):
S2-6 LibraryStore поверх каталога → S2-7 Экраны → S2-8 Поиск → S2-9 Плейлисты UI
→ S2-11 Полиш бэклога → S2-12 Финальный прогон
```

---

## S2-1: ZverCore — GRDB и схема каталога (TDD)

**Files:** `Packages/ZverCore/Package.swift` (зависимость GRDB), Create: `Sources/ZverCore/Catalog/Catalog.swift`, `Sources/ZverCore/Catalog/TrackRecord.swift`; Test: `Tests/ZverCoreTests/CatalogTests.swift`

- Package.swift: `.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")`, таргет ZverCore зависит от продукта `GRDB`.
- `Catalog`: обёртка `DatabaseQueue` + `DatabaseMigrator`; `init(path:)` и `static func inMemory()` (для тестов).
- Миграция v1, таблицы:
  - `track`: `relativePath TEXT PRIMARY KEY` (путь от Documents — стабилен между реинсталлами), `title NOT NULL`, `artist`, `album`, `trackNumber`, `year`, `duration NOT NULL`, `sampleRate NOT NULL`, `bitDepth`, `artworkFilePath` (относительный путь к folder.jpg, заполняется с S2-5), `addedAt DATETIME NOT NULL`
  - `playlist`: `id INTEGER PK AUTOINCREMENT`, `title NOT NULL`, `createdAt NOT NULL`
  - `playlistTrack`: `playlistId REFERENCES playlist ON DELETE CASCADE`, `trackRelativePath REFERENCES track ON DELETE CASCADE`, `position INTEGER NOT NULL`, PK (playlistId, trackRelativePath)
- `TrackRecord`: FetchableRecord/PersistableRecord; конвертация в/из `Track` через `documentsURL` (Track.url = documents + relativePath).
- TDD: миграция на пустой БД проходит; insert→fetch roundtrip сохраняет все поля; повторная миграция идемпотентна.

## S2-2: ZverCore — CatalogStore: сверка и выборки (TDD)

**Files:** Create: `Sources/ZverCore/Catalog/CatalogStore.swift`; Test: `Tests/ZverCoreTests/CatalogStoreTests.swift`

API (все методы синхронные, вызываются с фоновой очереди LibraryStore):
- `reconcile(scanned: [TrackRecord])` — upsert всех + DELETE треков, чьих relativePath нет в scanned (файл удалён). Плейлисты чистятся каскадом.
- `allTracks(documentsURL:) -> [Track]`
- `search(_ query: String, documentsURL:) -> [Track]` — LIKE по title/artist/album, escape `%_`, пустой запрос → [].
- TDD: reconcile добавляет/обновляет/удаляет; поиск находит по подстроке без регистра (включая кириллицу через LOWER? — SQLite LOWER не умеет кириллицу: использовать `localizedCaseInsensitiveContains` поверх выборки ИЛИ хранить нормализованные колонки; для MVP — фильтр в Swift по выбранным allTracks, это честно задокументировать).

## S2-3: ZverCore — плейлисты в каталоге (TDD)

**Files:** Create: `Sources/ZverCore/Catalog/PlaylistStore.swift` (+ структура `Playlist { id, title, trackRelativePaths }`); Test: `Tests/ZverCoreTests/PlaylistStoreTests.swift`

API: `createPlaylist(title:) -> Playlist`, `renamePlaylist(id:title:)`, `deletePlaylist(id:)`, `allPlaylists()`, `tracks(in: id, documentsURL:) -> [Track]`, `add(trackPath:to:)` (в конец, position = max+1, дубликаты игнорировать), `remove(trackPath:from:)`, `move(trackPath:in:to position:)` (пересчёт позиций).
TDD: порядок сохраняется и перенумеровывается после move/remove; удаление трека из каталога убирает его из плейлистов (каскад).

## S2-4: ZverMetadata — альбом из имени папки (TDD)

**Files:** Modify: `Sources/ZverMetadata/LibraryScanner.swift` (или MetadataReader — где чище); Test: дополнить `LibraryScannerTests`

Если у файла нет тега ALBUM и файл лежит НЕ в корне сканируемой директории — `album` = имя непосредственной родительской папки. ARTIST не трогаем. TDD: notags.flac в подпапке «Мой альбом» → album == «Мой альбом»; notags.flac в корне → album == nil.

## S2-5: ZverMetadata — обложка из файла в папке (TDD)

**Files:** Modify: `Sources/ZverMetadata/AudioFileInfo.swift` (+ `artworkFileURL: URL?`), `LibraryScanner.swift`; Test: дополнить

Если у трека нет встроенного артворка — поискать в его папке файл `cover|folder|front|albumart` с расширением `jpg|jpeg|png` (без учёта регистра, первый по этому приоритету имён) → `artworkFileURL`. Встроенный артворк всегда приоритетнее. TDD: папка с notags.flac и folder.jpg → artworkFileURL указывает на folder.jpg; tagged (со встроенной обложкой) рядом с folder.jpg → artworkFileURL может быть nil (embedded приоритет — решить и зафиксировать в тесте).

## S2-6: ZverIOS — LibraryStore поверх каталога

**Files:** Modify: `Sources/Library/LibraryStore.swift`, `Sources/ZverIOSApp.swift`/`ContentView.swift` (инициализация Catalog)

- Catalog открывается в Application Support (`catalog.sqlite`; создать каталог при отсутствии). НЕ в Documents — чтобы не попадал в скан и file sharing.
- Старт: мгновенно publish из `allTracks` → параллельно фоновый рескан Documents → `reconcile` → republish. Pull-to-refresh = тот же рескан.
- Маппинг AudioFileInfo → TrackRecord: relativePath от Documents, artworkFilePath из artworkFileURL.
- Track получает доступ к artwork файлу: ArtworkLoader: embedded → если nil, грузить artworkFilePath (поле добавить в Track в ZverCore — мелкая правка, согласовать с S2-1/S2-5 полями).
- Ошибка скана НЕ затирает уже опубликованный список (бэклог ревью).
- Билд + UI smoke остаётся зелёным.

## S2-7: ZverIOS — экраны библиотеки

**Files:** Create: `Sources/Library/ArtistsView.swift`, `AlbumsGridView.swift`, `AlbumDetailView.swift`; Modify: `LibraryView.swift`, `ContentView.swift`

Структура как в Apple Music: корневой экран «Библиотека» — NavigationStack со списком разделов: Плейлисты (S2-9), Артисты, Альбомы, Песни.
- Артисты: алфавитный список (из группировки по artist) → экран артиста: его альбомы → AlbumDetailView.
- Альбомы: grid 2 колонки, обложка + название + артист → AlbumDetailView (обложка крупно, треки, кнопки Играть/Перемешать).
- Песни: текущий flat-список по альбомным секциям (существующий LibraryView-контент) ИЛИ простой алфавитный список треков — решить по простоте.
- Бейдж формата сохраняется в рядах треков. Мини-плеер поверх всех экранов (как сейчас).

## S2-8: ZverIOS — поиск

**Files:** Create: `Sources/Library/SearchView.swift`; Modify: `ContentView.swift` (TabView: Библиотека / Поиск)

`.searchable`, debounce не нужен (локальная БД). Результаты секциями: Артисты / Альбомы / Песни. Тап по треку — играет (очередь = результаты секции), по альбому/артисту — навигация на их экраны.

## S2-9: ZverIOS — плейлисты UI

**Files:** Create: `Sources/Library/PlaylistsView.swift`, `PlaylistDetailView.swift`; Modify: контекст-меню рядов треков во всех списках

- Раздел «Плейлисты»: список + «Новый плейлист» (alert с полем имени). Swipe-to-delete, переименование через контекст-меню.
- Экран плейлиста: треки по позициям, Играть, EditMode для reorder/удаления.
- Контекст-меню на ряде трека (везде): «В плейлист…» → меню со списком плейлистов + «Новый…».

## S2-10: PlayerEngine — gapless

**Files:** Modify: `Sources/Audio/PlayerEngine.swift`

- После schedule текущего файла: вычислить следующий трек из `queue.tracks`/`queue.currentIndex` (поля публичные). Если есть и `AVAudioFile(forReading:)` следующего имеет ТОТ ЖЕ sampleRate и channelCount — `player.scheduleFile(next, at: nil, completionCallbackType: .dataPlayedBack)` сразу же (нода играет подряд без зазора).
- Бухгалтерия позиций: `sampleTimeBase: AVAudioFramePosition` — при завершении трека N (его completion) base += N.file.length; `currentTime = (playerTime.sampleTime - sampleTimeBase + startFrame) / rate`. Completion текущего: advance очереди/UI БЕЗ остановки ноды (трек уже играет следующий), обновить file/Now Playing/artwork и предпланировать следующий-следующий.
- Если частота следующего отличается — НЕ предпланировать; completion идёт штатным путём loadAndPlay (микропауза на переключение ЦАПа — ожидаемо).
- seek/stop/ручная смена трека: generation++ инвалидирует все completions, sampleTimeBase = 0, предпланирование сбрасывается и пересоздаётся.
- ВНИМАНИЕ (краш-класс этапа 1): completion-замыкания НЕ должны наследовать MainActor-изоляцию — существующий паттерн Task { @MainActor } сохранить; не вводить новых замыканий, передаваемых в системные API из @MainActor-контекста без @Sendable.
- Параллельная работа: пока цепочка P правит Packages/ZverCore — перед финальным билдом дождаться чистоты (цикл: git status --porcelain Packages/ пуст, sleep 30, до 20 раз).
- Проверка: билд; UI smoke зелёный; слуховая проверка стыка — пользователем позже.

## S2-11: ZverIOS — полиш по бэклогу ревью этапа 1

**Files:** Modify: `ContentView.swift`, `MiniPlayerBar.swift`, `PlayerScreen.swift`, `ArtworkLoader.swift`, `LibraryView.swift`, `project.yml`

1. Мини-плеер через `.safeAreaInset(edge: .bottom)` — не перекрывать последние ряды списков.
2. ArtworkLoader: синхронный cache-peek (`func cached(for:) -> UIImage?`) — без мigания плейсхолдера при смене трека; дедупликация in-flight загрузок (кэш Task по track.id).
3. PlayerScreen: сброс isScrubbing/scrubTime при смене track.id (авто-переход во время драга).
4. `accessibilityLabel` на кнопки транспорта (Назад/Играть/Пауза/Вперёд) в обоих плеерах.
5. LibraryView: textCase(nil) и на заголовок альбома (сейчас аперкейсится системой).
6. project.yml: `CFBundleShortVersionString: $(MARKETING_VERSION)`, `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` в info.properties (+ регенерация и коммит Info.plist).
7. LibraryStore: guard от параллельных refresh (in-flight флаг).

## S2-12: финальный прогон и документация

- `swift test` оба пакета; билд приложения; UI smoke на симуляторе (фикстуры сидировать через simctl get_app_container, см. scripts/make-fixtures.sh).
- README: раздел «Что умеет» дополнить (каталог, плейлисты, поиск, gapless, фоллбэки импорта).
- `docs/manual-test-checklist.md`: добавить пункты этапа 2 (gapless на стыке треков одного альбома; обложка из folder.jpg на In Rainbows; «Без альбома» больше не появляется для папок без тегов; плейлист создаётся/переживает рестарт; поиск находит трек; библиотека открывается мгновенно после рестарта).
- Установить свежий билд на iPhone пользователя (xcodebuild + devicectl, команды из истории).

## Definition of Done

Все тесты зелёные (пакеты + UI smoke), билд на устройство установлен, пользователь прошёл новые пункты чеклиста. Дальше — этап 3 «Синк с Мака».
