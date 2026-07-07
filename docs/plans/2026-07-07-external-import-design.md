# Импорт из внешних источников: Bandcamp, Internet Archive, файлы

Музыка попадает в библиотеку прямо с телефона, без Мака. Вкладка «Импорт»
превращается в селектор источников: Мак (как сейчас), Bandcamp (webview
с перехватом скачивания), Internet Archive / Live Music Archive (нативный
поиск + FLAC), «Из файлов», плюс системное «Открыть в Zver Media» из
Safari/Files/AirDrop/почты.

## Факты, на которых стоит дизайн (проверено ресёрчем 2026-07-07)

- **FLAC-стриминга у Bandcamp не существует**: стрим — всегда MP3-128
  (официальная справка), lossless — только скачиванием. Модель: превью
  слушаем их плеером в webview, FLAC качаем в библиотеку.
- FLAC/WAV/AIFF-скачивание **сохраняет битность/частоту оригинала**
  (24/96 останется 24/96) — официальная справка Bandcamp.
- Альбом отдаётся **zip-архивом** (треки + обложка), трек — файлом.
  URL скачивания (`pN.bcbits.com/download/...`) подписанный и
  времяограниченный.
- ToS/AUP Bandcamp запрещают **автоматизацию** (скрипты, скрейпинг),
  ручные действия пользователя в браузере — обычное использование.
  Поэтому: пользователь сам жмёт «buy → $0 → download» (и решает
  капчу/логин), приложение лишь перехватывает файл. Автоматизацию
  $0-чекаута сознательно не делаем.
- Логин в webview с персистентными куками
  (`WKWebsiteDataStore.default()`) — коллекция купленного доступна,
  redownload без повторной оплаты.
- Internet Archive (Live Music Archive): легальные концерты во FLAC
  (включая 24-bit), официальные API без ключей
  (`advancedsearch.php`, `/metadata/{id}`, `/download/{id}/{file}`,
  Range поддерживается).
- Share extension НЕ делаем: расширения тратят лимит App ID бесплатного
  Apple ID и ломают переподпись AltStore. `CFBundleDocumentTypes`
  не стоят ничего и дают «Открыть в…» + приём AirDrop.

## Архитектура

Чистая логика — в новом пакете, тонкие адаптеры — в приложении
(инвариант всех этапов).

### Новый пакет `Packages/ZverImport`

Зависимости: `ZverMetadata` (MetadataReader, LibraryScanner-расширения),
`ZverTransport` (AlbumIdentity, Sha256), **ZIPFoundation** (SPM,
`from: "0.9.0"`) — вторая внешняя зависимость репо после GRDB;
Compression/AppleArchive zip-контейнер не читают, свой парсер — YAGNI.

- `ZipExtractor` — распаковка во временную папку:
  защита от zip-slip (отказ на `..`/абсолютные пути), белый список
  расширений (аудио из `LibraryScanner` + `jpg/jpeg/png/cue/m3u/m3u8/
  log/txt`), лимит распакованного размера, zip64 (hi-res альбомы > 4 ГБ).
- `AlbumImporter` — ядро фичи:
  - `init(libraryRoot: URL)` — `Documents/Library`;
  - `importArchive(_ zipURL: URL) async throws -> [ImportResult]` —
    распаковать в `FileManager.temporaryDirectory` (тот же том, move
    атомарен), прочитать теги каждого трека `MetadataReader.read(url:)`,
    сгруппировать по (artist, album); нет тега ALBUM — фоллбэк на имя
    корневой папки архива / имя zip (у Bandcamp это `Artist - Album`);
  - `importFiles(_ urls: [URL]) async throws -> [ImportResult]` — то же
    для россыпи файлов (Internet Archive, document picker);
  - раскладка: `Documents/Library/<AlbumIdentity.folderName(artist:
    title:year:)>/<fileName>`, поддиректории архива сохраняются
    (multi-disc уже понимает сканер); папка существует — докладываем
    недостающие файлы, существующие не трогаем (идемпотентный повтор);
  - источник (zip/staging) удаляется после успеха;
  - `ImportResult { albumFolder: URL, artist: String?, album: String,
    trackCount: Int }`.
  - Рескан НЕ дёргает — это делает вызывающий (`rescan`-замыкание
    вкладки «Импорт» уже прокинуто из `ContentView.swift:102`).
- `ArchiveOrgClient` — чистые построители запросов + Codable-разбор
  (поиск `collection:(etree)`, метадата с файлами, фильтр форматов
  `Flac`/`24bit Flac`, download-URL). Сеть — через существующий
  паттерн `URLSession`, тесты на записанных JSON.

### Приложение (Apps/ZverIOS)

**Вкладка «Импорт» → селектор источников.** Корнем вкладки становится
`ImportHomeView` (List в существующем NavigationStack): «С Мака»
(текущий `MacImportView` без изменений), «Bandcamp», «Internet Archive»,
«Из файлов» (`fileImporter`, типы zip/audio). `rescan`-замыкание
раздаётся всем источникам.

**«Открыть в Zver Media» (системный импорт).**
- `project.yml`/Info.plist: `CFBundleDocumentTypes`
  (`LSItemContentTypes`: `public.zip-archive`, `public.audio`,
  `org.xiph.flac`; `LSHandlerRank: Alternate`) +
  `UTImportedTypeDeclarations` для `dsf` (iOS его UTI не знает).
- `ZverIOSApp`/`ContentView`: `.onOpenURL` → security-scoped доступ →
  копия в staging (tmp) → `AlbumImporter` → баннер «Импортирован
  <артист — альбом>» → `library.refresh()`.
- `LibraryScanner`: пропускать `Documents/Inbox` (туда система кладёт
  «Copy to Zver» — сырьё не должно попадать в скан до импорта).

**Bandcamp: `BandcampImportView`.**
- `WKWebView` (первое использование WebKit в проекте) со стартом на
  `bandcamp.com`, `websiteDataStore = .default()` — куки персистентны,
  **логин переживает перезапуск** (требование). Тулбар: назад/вперёд/домой.
- Перехват: `decidePolicyFor navigationResponse` — если
  `!canShowMIMEType` или MIME `application/zip`/`audio/*` → `.download`;
  `WKDownloadDelegate.decideDestinationUsing` → tmp; прогресс из
  `download.progress`; по завершении → `AlbumImporter` → баннер + рескан.
- Скачивания живут в `@MainActor WebDownloadCenter: ObservableObject`
  (владеет вью-стек «Импорта», не сама вкладка webview) — плашка
  прогресса видна из селектора источников. Ограничение MVP: WKDownload
  умирает вместе с процессом — при уходе из приложения докачки нет;
  предупреждаем в UI. v2: отменять WKDownload и переигрывать его
  `originalRequest` через background `URLSession` (bcbits-ссылки
  подписаны в самом URL).

**Internet Archive: `ArchiveImportView`.**
- Нативный поиск (артист/название) → карточки концертов (title, creator,
  year, downloads) → экран релиза: список FLAC-файлов из `/metadata`,
  кнопка «Скачать альбом».
- Скачивание: последовательная очередь `URLSession.downloadTask` +
  Range-докачка (паттерн `DownloadEngine`), файлы в staging-папку →
  `importFiles` → рескан. Прогресс по файлам в том же
  `WebDownloadCenter`-стиле.

### Отложено (сознательно)

- **Jamendo** — CC-каталог с FLAC 16/44 через официальный API: интерфейс
  источников расширяем, добавим по желанию (нужен бесплатный client_id).
- **Wi-Fi upload** (HTTP-сервер на телефоне, фундамент в ZverTransport
  есть) — отдельный мини-этап, если понадобится.
- Qobuz/HDTracks (файлы с телефона не отдают), FMA (API закрыт),
  стрим-рипы MP3-128 (мусор для hi-res системы) — не делаем.

## План внедрения

1. **Пакет ZverImport: ZipExtractor.** Package.swift (ZverMetadata,
   ZverTransport, ZIPFoundation), распаковка + zip-slip + белый список
   + лимиты. Тесты swift-testing на фикстурах-зипах (собрать в тестах
   же через ZIPFoundation: нормальный альбом, `../evil`, чужие
   расширения).
2. **AlbumImporter.** Группировка по тегам (`MetadataReader`), фоллбэки
   имени альбома, раскладка через `AlbumIdentity.folderName`,
   идемпотентный повтор, удаление источника. Тесты на аудио-фикстурах
   `scripts/make-fixtures.sh`.
3. **«Открыть в Zver».** `project.yml` (+ регенерация xcodegen),
   `.onOpenURL` → staging → импорт → баннер → refresh; пропуск
   `Documents/Inbox` в `LibraryScanner` (+ тест). Первая
   пользовательская ценность: Bandcamp работает «через Safari».
4. **Селектор источников.** `ImportHomeView`, переезд `MacImportView`
   внутрь, «Из файлов» через `fileImporter` → тот же импорт-путь.
5. **Bandcamp-вкладка.** `BandcampWebView` (UIViewRepresentable) +
   `WebDownloadCenter` + перехват WKDownload → AlbumImporter. Ручная
   проверка на реальном $0-релизе (чек-лист).
6. **Internet Archive.** `ArchiveOrgClient` (тесты на JSON-фикстурах) +
   `ArchiveImportView` + очередь скачиваний с Range-докачкой.

Каждый пункт — отдельный коммит/PR-цикл с зелёными
`swift test --package-path Packages/ZverImport` и сборкой
`xcodegen generate && xcodebuild`.

## Верификация

- ZverImport: тесты экстрактора (zip-slip, фильтры, лимиты), импортера
  (группировка, фоллбэки, идемпотентность), ArchiveOrgClient (разбор
  search/metadata, построение URL).
- ZverMetadata: тест пропуска `Inbox`.
- Руками на устройстве (manual-test-checklist.md): «Открыть в Zver» из
  Safari и Files (zip и одиночный flac), AirDrop, Bandcamp $0-релиз
  (24-bit — проверить битность в плеере), логин Bandcamp переживает
  перезапуск, IA-концерт качается с обрывом сети (докачка), повторный
  импорт того же альбома не плодит дублей.
