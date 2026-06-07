# Zver Media — Этап 3 «Синк с Мака»: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: исполнение через dynamic workflow (конвейер
> имплементер → спек-ревью ∥ код-ревью качества → фикс-луп ≤2 круга), параллельные
> цепочки по графу зависимостей. Дисциплина параллельных агентов в одном репозитории:
> `git add` только своих путей (НИКОГДА `-A`), retry на `index.lock` (2с ×5), никаких
> `reset/checkout/stash`; задачи внутри одного SPM-пакета — последовательно (общий
> `.build`); перед билдом таргетов — дождаться чистоты `Packages/` (цикл
> `git status --porcelain Packages/` пуст, sleep 30, до 20 раз).

**Goal:** Mac-компаньон (`ZverMac`) и iOS-сторона импорта, дающие надёжную
pull-передачу альбомов Mac → iPhone: на Маке drag-drop папки → парсинг тегов →
редактор метадаты (правки не трогают исходные файлы) → исходящая очередь →
Bonjour-анонс + HTTP-раздача с докачкой; на iPhone — обнаружение Мака, pairing
6-значным кодом, докачиваемая загрузка с посимвольной SHA-256 сверкой, раскладка
в библиотеку и reconcile каталога с подтверждением Маку. Версионируемый протокол.

**Architecture.** Новый кросс-платформенный пакет `ZverTransport` (iOS 17 / macOS 14)
держит ВСЮ чистую логику синка — версионируемый JSON-манифест, SHA-256, pairing
(state machine + сообщения + `KeyStore`), дельта-планировщик, чистый разбор HTTP
(парсер запроса, резолвер диапазонов, роутинг) — за протоколами прячутся только
рантайм-сетевые объекты (`NWListener`/`NWBrowser`/`NWConnection`), которые остаются
тонкими непокрытыми адаптерами. Источник правды о метадате на устройстве — диск:
правки с Мака телефон кладёт рядом с треками версионируемым **sidecar**
`album.zvermeta.json` (тип в `ZverMetadata`), `LibraryScanner` накладывает его поверх
тегов файла → `catalog.sqlite` остаётся чисто пересобираемым кэшем (правки переживают
потерю/реинсталл БД, рескан идемпотентен, `reconcile` из этапа 2 не меняется).

**Решение по правкам метадаты (зафиксировано):** правки уходят в манифест, исходные
аудиофайлы НЕ перезаписываются. Телефон при импорте материализует правки на диск как
sidecar `album.zvermeta.json` в папке альбома; `LibraryScanner` читает теги файла и
накладывает overlay из sidecar (title/artist/album/year/trackNumber + обложка имеет
приоритет над встроенной, если задана в sidecar). Каталог получает уже правленые
значения при обычном рескане — отдельной «защиты от затирания» в БД не нужно, источник
правды — файловая система. См. обоснование в шапке (надёжность, идемпотентность,
переживание реинсталла, минимальный blast-radius на проверенный код этапов 1–2).

**Решение по HTTP-серверу (зафиксировано):** чистый **Network.framework**, не FlyingFox.
Обоснование: ноль внешних зависимостей (репозиторий остаётся на единственной — GRDB —
и собирается без сетевого fetch'а нового пакета), полный контроль над семантикой
Range/206/If-Range, необходимой для возобновляемой докачки hi-res. Что может быть
неверным (разбор строки запроса и заголовков, математика диапазонов, резолвинг
пути→файл, кадрирование Content-Length) — чистое и покрыто юнит-тестами в
`ZverTransport`; `NWListener`/`NWConnection` — тонкий адаптер в `ZverMac`. ETag для
файла = его sha256 из манифеста → встроенный resume `URLSession` (resume data + If-Range)
работает по контент-валидатору; а пост-загрузочная сверка SHA-256 + ретрай —
финальная гарантия целостности независимо от поведения resume. (FlyingFox остаётся
задокументированной альтернативой за тем же протоколом сервера, если понадобится.)

**Tech Stack:** + системные `Network`, `CryptoKit` (SHA-256, обе платформы),
`Security` (Keychain). Новых внешних SPM-зависимостей нет. `ZverMac` — новый
XcodeGen-проект (`Apps/ZverMac/project.yml` → `ZverMac.xcodeproj`, не трогает
`ZverIOS/project.yml`, его bundle id `dev.zver.ZverIOS` и DEVELOPMENT_TEAM).

**Контекст:** дизайн — `docs/plans/2026-06-06-zver-cloud-design.md` (там же выжимка
ресёрча: Bonjour/Network.framework, background URLSession + HTTP Range resume, Local
Network privacy, pairing из LocalSend — повторный веб-ресёрч не нужен). Этапы 1–2
завершены (плеер+ЦАП, каталог GRDB, экраны, плейлисты, gapless, 69 зелёных тестов).
Реальные данные: папки-раздачи `Radiohead - In Rainbows (2007) [24-44.1 WEB FLAC]/`
с `folder.jpg` внутри. Окружение этой машины: Xcode 26.4.1, Swift 6.3.1, симуляторных
рантаймов и девайсов нет — проверка таргетов ТОЛЬКО компиляцией
(`CODE_SIGNING_ALLOWED=NO`), `xcodebuild test`/`simctl` ЗАПРЕЩЕНЫ; тесты пакетов
(`swift test`) работают как обычно.

## Протокол синка (фиксируется в S3-1, версия 1)

```
GET  /manifest                          → SyncManifest (JSON), требует X-Zver-Token
GET  /album/<albumId>/<fileName>        → файл, поддержка Range/206/If-Range, X-Zver-Token
POST /pair       { code }               → { token }       (только в окне pairing)
POST /confirm    { albumId }            → 200             (Mac убирает альбом из очереди)
Bonjour: тип _zver._tcp, TXT: name=<имя Мака>, v=1
```

`SyncManifest { protocolVersion:Int, albums:[ManifestAlbum] }`
`ManifestAlbum { id, title, artist?, year?, artwork?:ManifestArtwork, tracks:[ManifestTrack] }`
`ManifestTrack { fileName, title, artist?, album?, trackNumber?, year?, duration, sampleRate, bitDepth?, fileSize, sha256, fileExtension }`
`ManifestArtwork { fileName, sha256, fileSize }`
`albumId` — детерминированный санитизированный `<artist> - <title> (<year>)` (перезаливка
обновляет на месте, без дублей). Файлы на телефоне: `Documents/Library/<albumId>/<fileName>`.

## Граф исполнения

```
Параллельные цепочки (разные пакеты/директории — без общих файлов):
├─ T (ZverTransport, внутри пакета — последовательно из-за общего .build):
│     S3-1 манифест+протокол → S3-2 SHA-256 → S3-3 pairing → S3-4 Bonjour
│     → S3-5 дельта-планировщик → S3-6 чистый HTTP (парсер/диапазоны/роутинг)
├─ M (ZverMetadata):  S3-7 sidecar overlay в сканере
└─ X (ZverMac каркас): S3-8 проект + меню-бар/окно + drag-drop + превью + редактор + очередь
Затем интеграция (T+M+X готовы), две параллельные под-цепочки (разные таргеты):
├─ Mac:  S3-9  сервер+Bonjour+pairing-host+confirm на ZverMac
└─ iOS:  S3-10 обнаружение+pairing-client+экран «Импорт с Мака»
         → S3-11 докачиваемая загрузка + SHA-сверка + раскладка + reconcile + confirm
Финал: S3-12 билд обоих таргетов + swift test всех пакетов + README + чеклист
```

---

## S3-1: ZverTransport — пакет и версионируемый манифест (TDD)

**Files:** Create `Packages/ZverTransport/Package.swift`,
`Sources/ZverTransport/Manifest/SyncManifest.swift`,
`Sources/ZverTransport/Manifest/ManifestAlbum.swift` (ManifestAlbum/ManifestTrack/ManifestArtwork);
Test `Tests/ZverTransportTests/ManifestTests.swift`.

- `Package.swift`: `swift-tools-version: 6.0`, `platforms: [.iOS(.v17), .macOS(.v14)]`,
  продукт-библиотека `ZverTransport`, БЕЗ внешних зависимостей (Network/CryptoKit/Security —
  системные, линкуются по `import`).
- Типы `Codable, Equatable, Sendable` строго по схеме раздела «Протокол синка».
  `SyncManifest.currentProtocolVersion = 1`. `protocolVersion` сериализуется явным полем.
- TDD: round-trip encode→decode сохраняет все поля; декод манифеста с НЕИЗВЕСТНЫМИ
  лишними ключами не падает (forward-compat); декод с `protocolVersion` отличным от
  текущего — успешно парсится, доступен вызывающему для решения (несовместимость —
  это не «пустой манифест»); стабильный порядок ключей не требуется.

## S3-2: ZverTransport — SHA-256 хелпер (TDD)

**Files:** Create `Sources/ZverTransport/Sha256.swift`;
Test `Tests/ZverTransportTests/Sha256Tests.swift`.

- `enum Sha256`: `hash(_ data: Data) -> String` (hex, нижний регистр) на CryptoKit;
  `hash(fileURL: URL) throws -> String` — потоково через `FileHandle` чанками (напр.
  1 МБ), без загрузки всего файла в память (hi-res — сотни МБ).
- TDD: известные векторы (`""` → e3b0c4…, `"abc"` → ba7816…); `hash(data:)` и
  `hash(fileURL:)` совпадают на одном содержимом (писать во временный файл);
  большой файл (> размера чанка) хешируется корректно; недоступный файл — throw.

## S3-3: ZverTransport — pairing (TDD)

**Files:** Create `Sources/ZverTransport/Pairing/PairingMessages.swift`
(`PairRequest{code}`, `PairResponse{token}`, Codable), `Pairing.swift`
(генерация 6-значного кода через `SystemRandomNumberGenerator`, выпуск токена,
проверка кода), `KeyStore.swift` (протокол `save/token/delete(forService:)` +
`InMemoryKeyStore`), `KeychainKeyStore.swift` (тонкий адаптер `Security`, обе
платформы — непокрыт); Test `Tests/ZverTransportTests/PairingTests.swift`,
`KeyStoreTests.swift`.

- Хост (Мак): при открытии окна pairing генерирует код (6 цифр, ведущие нули
  допустимы — хранить строкой) и одноразовый `token` (напр. 256-бит hex). Клиент
  (телефон) шлёт `PairRequest{code}`; хост сверяет (константное по времени сравнение)
  → `PairResponse{token}`. Обе стороны кладут `token` в `KeyStore` под сервисом
  (имя/host Мака). Дальше запросы несут `X-Zver-Token: <token>` — повторный pairing
  не нужен.
- Чистая логика (генерация/сверка кода, выпуск токена, кодирование сообщений,
  `InMemoryKeyStore`) — под TDD. `KeychainKeyStore` — адаптер, тестами не покрываем
  (Keychain недоступен в `swift test` без подписи/entitlements).
- TDD: код — ровно 6 цифр; верный код → токен, неверный → отказ; round-trip сообщений;
  `InMemoryKeyStore` save→token→delete; пустой токен для неизвестного сервиса → nil.

## S3-4: ZverTransport — Bonjour за протоколами (TDD)

**Files:** Create `Sources/ZverTransport/Discovery/ServiceAdvertiser.swift`
(протокол + `NWServiceAdvertiser` адаптер на `NWListener`),
`ServiceBrowser.swift` (протокол + `NWServiceBrowser` адаптер на `NWBrowser`,
тип `DiscoveredService{name, host?, port?}`),
`DiscoveredServiceRegistry.swift` (чистый реестр: add/remove/list, дедуп по `name`,
сортировка по имени); Test `Tests/ZverTransportTests/DiscoveredServiceRegistryTests.swift`.

- `ServiceAdvertiser` протокол: `start(port:txt:) / stop()`. `ServiceBrowser` протокол:
  `start(onChange: @Sendable ([DiscoveredService]) -> Void) / stop()`. Адаптеры
  публикуют/браузят тип `_zver._tcp` — тонкие, непокрытые (лессон: рантайм-сетевые
  объекты за протоколами).
- Замыкания в адаптерах, передаваемые в `NW*` и вызываемые на сетевых очередях, —
  `@Sendable`, внутрь `Task { @MainActor in … }` на стороне UI (краш-класс Swift 6
  из этапа 1: не наследовать `@MainActor`-изоляцию в фоновые колбэки).
- TDD: реестр дедуплицирует по имени (повторный add того же имени обновляет, не
  дублирует); remove убирает; list отсортирован; чистый, без сети.

## S3-5: ZverTransport — дельта-планировщик (TDD)

**Files:** Create `Sources/ZverTransport/SyncPlanner.swift`;
Test `Tests/ZverTransportTests/SyncPlannerTests.swift`.

- `SyncPlanner.plan(manifest:, localShasByPath: [String: String]) -> SyncPlan`, где
  ключ — относительный путь `"<albumId>/<fileName>"`. `SyncPlan { toFetch:[PlannedFile],
  alreadyComplete:[albumId] }`. Файл качаем, если его пути нет локально ИЛИ локальный
  sha ≠ sha манифеста; пропускаем при совпадении (идемпотентность/докачка). Альбом
  `alreadyComplete`, когда все его треки и обложка уже совпадают (для немедленного
  confirm без скачивания).
- Артворк альбома участвует в плане как отдельный `PlannedFile` (если задан).
- TDD: новый альбом → все файлы в `toFetch`; идентичный (совпали sha) → пусто +
  `alreadyComplete`; изменённый один трек → только он; перезаливка с правленым
  sidecar не влияет на список (sidecar не аудиофайл, в манифесте отдельно) —
  зафиксировать поведение тестом.

## S3-6: ZverTransport — чистый разбор HTTP (TDD)

**Files:** Create `Sources/ZverTransport/HTTP/HTTPRequestParser.swift`
(инкрементальный: `feed(Data) -> ParseResult{.needMore | .request(HTTPRequest) }`,
`HTTPRequest{method, path, headers:[String:String]}`),
`ByteRange.swift` (`parse(header:String?, fileSize:Int) -> RangeResult{.full | .partial(start,end) | .unsatisfiable}`),
`HTTPRouter.swift` (`resolve(path:) -> Route{.manifest | .album(id,fileName) | .pair | .confirm | .notFound}`),
`HTTPResponseHead.swift` (билдер статус-строки и заголовков: 200/206/404/416,
Content-Length, Content-Range, Accept-Ranges: bytes, ETag, Content-Type);
Test `Tests/ZverTransportTests/HTTPRequestParserTests.swift`, `ByteRangeTests.swift`,
`HTTPRouterTests.swift`.

- Парсер: накапливает байты до `\r\n\r\n`, разбирает request-line + заголовки
  (без тела для GET; для POST — отдать длину тела по Content-Length вызывающему).
  Разбит TCP-сегментами → `.needMore` пока заголовки неполны.
- `ByteRange`: одиночный `bytes=start-end`, `bytes=start-`, `bytes=-suffix`; кламп;
  пустой/битый Range → `.full`; вне границ → `.unsatisfiable` (416).
- `HTTPRouter`: маппинг путей протокола; percent-decoding `fileName`; защита от
  `..`/абсолютных путей (path traversal) — такой путь → `.notFound`.
- TDD: парсер по кускам собирает запрос; заголовки регистронезависимы по имени;
  Range все формы + кламп + unsatisfiable; роутер — все ветки + перкодинг +
  отвергает traversal.

## S3-7: ZverMetadata — sidecar overlay в сканере (TDD)

**Files:** Create `Sources/ZverMetadata/AlbumSidecar.swift`
(`AlbumSidecar{version, album?, artworkFileName?, tracks:[String: TrackOverride]}`,
`TrackOverride{title?, artist?, album?, year?, trackNumber?}`, Codable, ключ —
`fileName`); Modify `LibraryScanner.swift`, при необходимости `MetadataReader.swift`/
`AudioFileInfo`; Test дополнить `LibraryScannerTests.swift`, новый
`AlbumSidecarTests.swift`.

- Имя sidecar — константа `album.zvermeta.json`. При скане папки: если файл есть и
  валиден — для каждого трека наложить `TrackOverride` поверх прочитанных тегов
  (любое непустое поле override побеждает тег). `artworkFileName` из sidecar →
  `artworkFileURL` указывает на него и ПОБЕЖДАЕТ встроенную обложку (в отличие от
  обычного фоллбэка, где embedded приоритетнее) — чтобы правленая на Маке обложка
  показывалась. Кэшировать чтение sidecar по папке (как уже сделано для обложек).
- Битый/нечитаемый sidecar — игнор (фоллбэк к тегам), скан не падает. `.json` не
  входит в audioExtensions → сам sidecar в скан не попадает.
- TDD: `notags.flac` + sidecar с title/artist/album → правленые значения; sidecar
  `artworkFileName` рядом с файлом, у которого ЕСТЬ встроенная обложка → artworkFileURL
  = файл из sidecar (override побеждает embedded); отсутствие sidecar → поведение
  этапа 2 без изменений; битый sidecar → теги файла. (Фикстуры sidecar генерировать
  в тесте во временной папке, копируя `notags.flac`/`tagged_16_44.flac`.)

## S3-8: ZverMac — каркас приложения, drag-drop, редактор, очередь (компиляция + TDD логики)

**Files:** Create `Apps/ZverMac/project.yml`, `Apps/ZverMac/Info.plist`,
`Apps/ZverMac/Sources/ZverMacApp.swift` (`MenuBarExtra` + `Window`),
`Sources/Import/DropController.swift` (приём папки, парсинг через `ZverMetadata`),
`Sources/Import/AlbumDraft.swift` (редактируемая модель: album-уровень
title/artist/year/обложка + per-track title/artist/trackNumber; правки в памяти,
исходные файлы не трогаются), `Sources/Import/ManifestBuilder.swift` (app-glue: `AlbumDraft` + sha по файлам через
`Sha256` → `ManifestAlbum`/`SyncManifest`), `Sources/Import/OutgoingQueue.swift`
(модель очереди), `Sources/UI/AlbumPreviewView.swift`, `Sources/UI/QueueView.swift`.

- **Чистая логика — в `ZverTransport`, не в app-таргете** (app не тестируется здесь:
  нет рантайма): `AlbumIdentity.folderName(artist:title:year:) -> String` (санитизация
  для `albumId`) добавляется в `ZverTransport` и покрывается `AlbumIdentityTests`
  (часть протокола — обе стороны должны выводить один и тот же `albumId`). Удобнее
  завести её ещё в S3-1 рядом с манифестом; здесь — только потребление. `ManifestBuilder`
  остаётся в app (зависит от `ZverMetadata.AudioFileInfo`) и лишь собирает данные +
  зовёт `Sha256`/`AlbumIdentity`.

- `project.yml`: platform macOS, deploymentTarget 14.0, SwiftUI; depends ZverCore,
  ZverMetadata, ZverTransport; `SWIFT_VERSION: 6.0`, `CODE_SIGN_STYLE: Automatic`,
  `DEVELOPMENT_TEAM: 6RWCS65D85` (тот же), `MARKETING_VERSION/CURRENT_PROJECT_VERSION`;
  info: `NSLocalNetworkUsageDescription` (RU-строка), `NSBonjourServices: [_zver._tcp]`,
  `LSUIElement` опционально (меню-бар). Bundle id `dev.zver.ZverMac`.
- Drag-drop папки на окно → `LibraryScanner.scan` → `AlbumDraft` с превью (обложка +
  список треков) и инлайн-редактором; «В очередь» → `OutgoingQueue`.
- Проверка: `xcodegen generate` + `xcodebuild -project ZverMac.xcodeproj -scheme ZverMac
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO build`; чистая логика
  (`AlbumIdentity`) — `swift test` в ZverTransport зелёный.

## S3-9: ZverMac — HTTP-сервер, Bonjour, pairing-host, confirm (компиляция)

**Files:** Create `Apps/ZverMac/Sources/Net/FileServer.swift` (NWListener: принимает
соединения, кормит байтами `HTTPRequestParser`, по `HTTPRouter` отдаёт манифест/файл/
обрабатывает pair/confirm; файл — потоково `FileHandle` чанками с учётом
`ByteRange`/206/`ETag = sha256`; авторизация `X-Zver-Token` кроме `/pair`),
`Sources/Net/SyncHost.swift` (связывает `OutgoingQueue` ↔ манифест и набор
раздаваемых файлов; обрабатывает confirm → удаляет альбом из очереди),
`Sources/Net/PairingHostController.swift` (окно с 6-значным кодом, выпуск токена,
`KeychainKeyStore`); Modify `ZverMacApp.swift`, `QueueView.swift` (статус/код/очередь).

- Сервер запускается при непустой очереди (или всегда в активном окне), публикует
  `_zver._tcp` через `NWServiceAdvertiser`. Один доверенный клиент в LAN; только GET
  (+ POST pair/confirm). Замыкания соединений — `@Sendable`, переходы в UI через
  `Task { @MainActor in }`.
- `ETag`/`If-Range`: ETag файла = его sha256 из манифеста; `If-Range` совпал → 206,
  иначе → 200 (полный) — чтобы resume `URLSession` был корректен.
- Проверка: компиляция таргета macOS (как в S3-8). Сетевой раздачи на этой машине
  не гоняем (ручная проверка — у владельца).

## S3-10: ZverIOS — обнаружение, pairing-client, экран «Импорт с Мака» (компиляция)

**Files:** Modify `Apps/ZverIOS/project.yml` (info: `NSLocalNetworkUsageDescription`
RU-строка, `NSBonjourServices: [_zver._tcp]`); Create
`Apps/ZverIOS/Sources/Import/MacImportView.swift` (список найденных Маков через
`NWServiceBrowser`/`DiscoveredServiceRegistry`), `Sources/Import/MacImportModel.swift`
(`@MainActor`: браузинг, выбор Мака, состояние pairing), `Sources/Import/PairingView.swift`
(ввод 6-значного кода → `PairRequest` → сохранить токен в `KeychainKeyStore`);
Modify `ContentView.swift` (точка входа в импорт — таб или кнопка в Библиотеке).

- Только обнаружение + pairing + загрузка манифеста (предпросмотр очереди Мака).
  Сам трансфер — S3-11. Браузер живёт, пока открыт экран.
- Колбэки браузера — `@Sendable`, в UI через `Task { @MainActor in }`.
- Проверка: `xcodegen generate` + `xcodebuild ... -destination "generic/platform=iOS
  Simulator" CODE_SIGNING_ALLOWED=NO build`; UI smoke не гоняем (нет рантайма).

## S3-11: ZverIOS — докачиваемая загрузка, SHA-сверка, раскладка, reconcile, confirm (компиляция)

**Files:** Create `Apps/ZverIOS/Sources/Import/DownloadEngine.swift`
(`URLSession` download, HTTP Range/resume data, per-file sha-сверка `Sha256`,
атомарная раскладка в `Documents/Library/<albumId>/<fileName>` + запись sidecar
`album.zvermeta.json` + файла обложки, прогресс), `Sources/Import/ImportCoordinator.swift`
(манифест → `SyncPlanner.plan` (локальные sha считаем по уже лежащим файлам) →
очередь загрузок → по завершении альбома: триггер рескана `LibraryStore.refresh()`
(reconcile подхватит правленые значения из sidecar) → `POST /confirm` Маку);
Modify `MacImportView.swift`/`MacImportModel.swift` (прогресс и старт загрузки),
возможно `LibraryStore.swift` (публичный метод дёрнуть рескан после импорта — без
изменения reconcile).

- Целостность: каждый файл после загрузки сверяется по sha256 манифеста; несовпадение
  → перекачать (resume/полностью). Раскладка атомарна (скачали во временный → проверили
  → `moveItem`). Sidecar пишется из манифеста (правленые поля + `artworkFileName`).
  Повторный запуск импорта продолжает с места (идемпотентно; план пропускает совпавшие).
- `confirm` шлём только когда ВСЕ треки альбома и обложка разложены и сверены.
- Дисциплина: при правках в `Packages/` дождаться чистоты перед билдом таргета.
- Проверка: компиляция iOS-таргета (как S3-10).

## S3-12: Финальный прогон и документация

**Files:** Modify `README.md`, `docs/manual-test-checklist.md`.

- `swift test` зелёный во всех трёх пакетах (ZverCore, ZverMetadata, ZverTransport).
- `xcodegen generate` + компиляция ОБОИХ таргетов: ZverIOS (`generic/platform=iOS
  Simulator`, `CODE_SIGNING_ALLOWED=NO`) и ZverMac (`platform=macOS`,
  `CODE_SIGNING_ALLOWED=NO`). Перед билдом — дождаться чистоты `Packages/`.
- README: новый блок про этап 3 (Mac-компаньон, синк, sidecar-правки, pairing),
  структура (+ Packages/ZverTransport, Apps/ZverMac), как собрать Mac-таргет.
- `docs/manual-test-checklist.md`: секция «Этап 3» — ручная проверка Mac↔iPhone у
  владельца (Мак и iPhone в одной сети): drag-drop альбома на Маке; правка названия/
  обложки уходит в превью не трогая файлы; обнаружение Мака на телефоне; pairing
  6-значным кодом (первый раз); загрузка очереди с прогрессом; обрыв сети на середине →
  докачка продолжается; правки с Мака видны в каталоге телефона; перезаливка того же
  альбома обновляет на месте (без дублей); альбом ушёл из очереди Мака после импорта;
  SHA-сверка отбраковывает битый файл.

## Definition of Done

`swift test` зелёные в ZverCore/ZverMetadata/ZverTransport; ОБА таргета (ZverIOS,
ZverMac) компилируются (`CODE_SIGNING_ALLOWED=NO`); README + manual-test-checklist
дополнены секцией этапа 3. Минорные замечания ревьюеров — в бэклог-отчёт, не чинить
вне скоупа. Ветка `stage3` запушена, в `main` не мерджится. Ручная проверка
Mac↔iPhone — у владельца. Дальше — этап 4 «Яндекс» (вне скоупа).
