# Zver Media — Этап 4 «Яндекс.Диск»: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: исполнение через dynamic workflow (конвейер
> имплементер → спек-ревью ∥ код-ревью качества → фикс-луп ≤2 круга), параллельные
> цепочки по графу зависимостей. Дисциплина параллельных агентов в одном репозитории:
> `git add` только своих путей (НИКОГДА `-A`), retry на `index.lock` (2с ×5), никаких
> `reset/checkout/stash`; задачи внутри одного SPM-пакета — последовательно (общий
> `.build`); перед билдом таргетов — дождаться чистоты `Packages/` (цикл
> `git status --porcelain Packages/` пуст, sleep 30, до 20 раз). Код-ревьюер — ДЕФОЛТНЫЙ
> workflow-агент (без `agentType:`), наследует Opus; null от ревьюера → needs-attention,
> а не тихий pass. Ревьюеры смотрят РЕАЛЬНЫЙ дифф файлов своей задачи (`git diff`/`git show`
> по путям), не доверяя слепо диапазону `baseSha..headSha` (в shared-tree он смазан).

**Goal:** Яндекс.Диск как холодный ярус хранения и бэкап для библиотеки на iPhone.
Новый storage-слой `ZverStorage` строго за протоколом `RemoteStore` (upload/download/
list/delete/exists) с реализацией `YandexDiskStore` (свой тонкий REST-клиент на
URLSession, ~6 эндпоинтов); очередь фонового бэкапа (2 параллельных файла, двухэтапная
схема href, докачка, exponential backoff на 429); жизненный цикл `fileState` в каталоге
(`local`/`uploading`/`backedUp`/`remote`/`downloading`) с идемпотентными транзакциями и
сверкой SHA-256 после каждой передачи; iOS-UI со статусом ☁️ в рядах треков, действиями
«Выгрузить»/«Скачать» и восстановлением (логин → скачать каталог → вся библиотека в облаке
→ качать нужное). Удаление локальной копии — ТОЛЬКО при подтверждённом checksum в облаке.

**Architecture.** Два новых блока, разнесённых по слоям:

1. **`Packages/ZverStorage`** (новый SPM, iOS 17 / macOS 14, зависит только от
   `ZverTransport` ради `Sha256`) — ВСЯ чистая логика облака: протокол `RemoteStore` +
   модели ресурсов/href/ошибок; `YandexWire` (построение `URLRequest` для ~7 эндпоинтов +
   разбор JSON-ответов и ошибок); `RetryPolicy` (классификация ошибок + exponential
   backoff с учётом `Retry-After`); `TransferState`/`BackupQueue` (модель состояний
   передачи и планировщик очереди — какой файл следующий, смещение докачки, ретраи, ≤2
   параллельных); `YandexOAuth` (чистое построение authorize-URL и разбор redirect).
   За протоколом прячется ЕДИНСТВЕННЫЙ рантайм-объект — `YandexDiskStore` (URLSession,
   фоновая сессия, двухэтапный href, `Content-Range` докачка), тонкий непокрытый адаптер.
   `InMemoryRemoteStore` — тестовый дубль для TDD очереди без сети.

2. **Каталог в `Packages/ZverCore`** — `fileState` как новое измерение строки `track`
   (миграция v2 добавляет колонки `fileState`, `cloudSha`; `FileState` enum + чистые
   правила переходов жизненного цикла; поля в `Track`/`TrackRecord`). `CatalogStore`
   получает идемпотентные апдейтеры состояния и — ГЛАВНОЕ — `reconcile` перестаёт удалять
   облачные треки: дисковый скан больше не «источник правды для удаления», каталог
   становится источником правды о наличии трека (offload-нутый `remote`-трек физически
   отсутствует на диске и обязан пережить рескан). Плюс `importRemoteCatalog` для
   восстановления (скачанный `catalog.sqlite.backup` → записи как `remote`).

**Ключевое архитектурное решение (зафиксировано).** До этапа 4 каталог — чисто
пересобираемый кэш: `reconcile(scanned:keepMissing:)` удаляет любой трек, чьего файла нет
на диске и `keepMissing` вернул false. С появлением `remote`-состояния это ломается:
выгруженный в облако трек НЕ имеет локального файла по дизайну. Поэтому `reconcile`
эволюционирует: трек, отсутствующий в скане, удаляется ТОЛЬКО если он не «облачный»
(`fileState ∈ {local, uploading}` И `cloudSha == nil`, т.е. никогда не подтверждён в
облаке) — тогда работает прежняя логика `keepMissing(файл на месте?)`. Треки в состояниях
`backedUp`/`remote`/`downloading` (или с непустым `cloudSha`) при отсутствии файла
СОХРАНЯЮТСЯ: они либо намеренно только в облаке, либо в процессе передачи. Это перенос
«источника правды о наличии» с ФС в каталог — ровно как обещает дизайн («Телефон — каталог-
источник правды; файлы — по требованию»). `addedAt` по-прежнему `noOverwrite`; `fileState`/
`cloudSha` тоже `noOverwrite` при upsert скана (скан их не знает и не должен затирать).

**Решение по OAuth (зафиксировано, с возможностью доработки позже).** Полноценный
`ASWebAuthenticationSession` требует зарегистрированного на oauth.yandex.ru приложения
(`client_id` + redirect URI), а эта машина OAuth не проверит. Поэтому MVP-вход — **ручной
отладочный токен**: владелец получает ~годовой OAuth-токен (scope `cloud_api:disk.app_folder`)
и вставляет в Настройках → токен ложится в Keychain (переиспользуем `KeychainKeyStore` из
`ZverTransport` с другим `account`). Storage НИКОГДА не хранит креды сам — `YandexDiskStore`
получает токен через инъекцию (`TokenProviding`), что делает смену способа входа тривиальной.
Чистая логика OAuth (построение authorize-URL, разбор `access_token` из redirect-fragment)
пишется и покрывается TDD СЕЙЧАС — чтобы позже подключить `ASWebAuthenticationSession` тонким
адаптером без переделок. Реальный выбор «регистрировать ли Яндекс-приложение» отложен.

**Решение по сетевому клиенту (зафиксировано):** для Яндекс REST — **URLSession** (а не
Network.framework, как в этапе 3 для HTTP-сервера): REST по HTTPS, фоновая сессия для
докачки при убитом приложении, стандартные `Range`/`Content-Range`. Что может быть неверным
(сборка URL/заголовков, разбор JSON-ответов и ошибок, математика backoff, выбор следующего
файла очереди) — ЧИСТОЕ и под TDD в `ZverStorage`; сам `URLSession`-адаптер `YandexDiskStore` —
тонкий, проверяется компиляцией, сетевую часть проверяет владелец на устройстве.

**Tech Stack:** + системные `Foundation`/`URLSession` (REST), `AuthenticationServices`
(только заготовка адаптера, в MVP не активна), `Security` (Keychain, переиспользование).
Новых внешних SPM-зависимостей НЕТ. `ZverStorage` добавляется в `Apps/ZverIOS/project.yml`
(iOS-таргет). `ZverMac` НЕ трогаем — этап 4 iOS-only; но общий `ZverCore` меняется (миграция
v2), поэтому Mac-таргет обязан продолжать компилироваться (финальная проверка).

**Контекст:** дизайн — `docs/plans/2026-06-06-zver-cloud-design.md`, разделы «Яндекс.Диск»
(выжимка ресёрча: REST живой, двухэтапный upload/download по временным href живут 30 мин,
докачка `Content-Range`, app-folder scope, async-операции с поллингом, WebDAV троттлится —
не использовать, OAuth без модерации, backoff на 429, ≤4 параллельных). Повторный веб-ресёрч
не нужен. Этапы 1–3 завершены (плеер+ЦАП, каталог GRDB, плейлисты, gapless; синк Mac→iPhone:
`ZverTransport`, `ZverMac`, импорт с докачкой), смёржены в `main`. Окружение: Xcode 26.4.1,
Swift 6.3.1, симуляторных рантаймов и девайсов нет — таргеты ТОЛЬКО компилируются
(`CODE_SIGNING_ALLOWED=NO`), `xcodebuild test`/`simctl`/`devicectl` ЗАПРЕЩЕНЫ; `swift test`
пакетов работает как обычно. Переиспользуем: `ZverTransport.Sha256` (потоковый SHA-256 файла),
`ZverTransport.KeychainKeyStore` (хранение токена), паттерн `RangeDownloading`/`DownloadEngine`
из этапа 3 (докачка + атомарная раскладка) — зеркалим для аплоада.

## Раскладка на Яндекс.Диске (app-folder scope)

```
app:/                                  (= Диск:/Приложения/Zver/ при scope disk.app_folder)
  catalog.sqlite.backup                бэкап каталога (для восстановления)
  library/<albumId>/<fileName>         аудиофайлы (имена = как в манифесте этапа 3)
```

`<albumId>` детерминирован (`ZverTransport.AlbumIdentity`, уже есть); `<fileName>` — имя
файла трека. Удалённый путь трека = `library/<relativePathБезПрефиксаLibrary>` — зеркало
локального `Documents/Library/<albumId>/<fileName>`. Базовый префикс (`app:/`) — настройка
`YandexDiskStore`, чтобы план Б (полный Диск без app-folder) или S3 меняли только адаптер.

## Эндпоинты Яндекс REST (фиксируются в S4-2; база `https://cloud-api.yandex.net/v1/disk`)

```
GET    /resources/upload?path=<p>&overwrite=true     → { href, method:"PUT", templated }
PUT    <href>            (тело = файл)                → 201/202        (двухэтапный аплоад)
GET    /resources/download?path=<p>                  → { href, method:"GET" }
GET    <href>   [Range: bytes=start-]                → 200/206        (докачка скачивания)
GET    /resources?path=<p>&fields=name,size,sha256,md5,type,_embedded.items.name,...
                                                     → ResourceMeta   (exists/list/сверка sha)
DELETE /resources?path=<p>&permanently=true          → 204 | 202+{href} (async, поллинг)
PUT    /resources?path=<p>                            → 201            (создать папку)
GET    <operation href>                              → { status }     (поллинг async-операции)
Заголовок авторизации всех запросов к API: `Authorization: OAuth <token>`
```

Классы ошибок: 401 (битый токен → фатально, перелогин), 403/404 (фатально), 409 (конфликт/
нет родителя), 423 (locked → ретрай с backoff), 429 (→ backoff, уважать `Retry-After`),
5xx (ретрай), 507 (нет места → фатально, показать).

## Жизненный цикл `fileState` (фиксируется в S4-7)

```
local ──upload──▶ uploading ──ok+shaОК──▶ backedUp ──«Выгрузить»(удалить локальный)──▶ remote
                      └────fail───────────┘ (откат в local)        remote ──«Скачать»──▶ downloading
downloading ──ok+shaОК──▶ backedUp ;  downloading ──fail──▶ remote (откат)
```

- `local` — файл на устройстве, в облаке ЕЩЁ нет (новый/импортированный трек).
- `uploading` — файл на устройстве, идёт выгрузка в облако.
- `backedUp` — файл на устройстве И подтверждён в облаке (`cloudSha` совпал) → можно
  безопасно выгрузить (удалить локальную копию).
- `remote` — файл ТОЛЬКО в облаке (локальная копия удалена), подразумевает наличие `cloudSha`.
- `downloading` — идёт скачивание из облака на устройство.
- `cloudSha` — SHA-256, подтверждённый в облаке (метаданные ресурса). Гейт удаления
  локальной копии: offload разрешён, только когда `cloudSha != nil` и равен локальному sha.

Переходы — чистая функция `FileState.canTransition(to:)` (валидные рёбра графа) + идемпотентность
в `CatalogStore` (повтор перехода после сбоя продолжает, не ломает). Скан НИКОГДА не меняет
`fileState` (только наполняет метаданные новых `local`-треков).

## Граф исполнения

```
Параллельные цепочки (разные пакеты — без общих файлов):
├─ S (ZverStorage, внутри пакета — последовательно из-за общего .build):
│     S4-1 пакет+RemoteStore+модели+InMemoryRemoteStore
│     → S4-2 YandexWire (запросы+разбор ответов/ошибок)
│     → S4-3 RetryPolicy (классификация+backoff)
│     → S4-4 TransferState+BackupQueue (планировщик, ≤2 параллельных, докачка)
│     → S4-5 YandexDiskStore (URLSession-адаптер, фон, href, Content-Range) [компиляция]
│     → S4-6 YandexOAuth (authorize-URL+разбор redirect, TokenProviding) [TDD чистого]
└─ C (ZverCore):  S4-7 миграция v2 + FileState + поля Track/TrackRecord
                  → S4-8 CatalogStore: апдейтеры состояния + reconcile-сохраняет-облако + restore
Затем интеграция (S+C готовы, чистота Packages/), iOS-таргет — последовательно (общие файлы app):
  S4-9  Аккаунт+Keychain-токен+экран Настроек (ручной вход) + ZverStorage в project.yml [компиляция]
  → S4-10 BackupService: связка CatalogStore↔BackupQueue↔YandexDiskStore, фон.сессия,
          сверка sha, переходы fileState, автобэкап новых альбомов, бэкап каталога [компиляция]
  → S4-11 UI: ☁️ бейдж в рядах + «Выгрузить»/«Скачать» + восстановление + проброс fileState
          через LibraryStore/Track [компиляция]
Финал: S4-12 swift test всех 4 пакетов + компиляция ОБОИХ таргетов (Mac-guard) + README + чеклист
```

---

## S4-1: ZverStorage — пакет, протокол RemoteStore, модели, тестовый дубль (TDD)

**Files:** Create `Packages/ZverStorage/Package.swift`,
`Sources/ZverStorage/RemoteStore.swift` (протокол + модели),
`Sources/ZverStorage/RemoteModels.swift` (`RemoteResource`, `UploadTarget`, `DownloadTarget`,
`RemoteError`), `Sources/ZverStorage/InMemoryRemoteStore.swift`;
Test `Tests/ZverStorageTests/InMemoryRemoteStoreTests.swift`,
`Tests/ZverStorageTests/RemoteModelsTests.swift`.

- `Package.swift`: `swift-tools-version: 6.0`, `platforms: [.iOS(.v17), .macOS(.v14)]`,
  продукт-библиотека `ZverStorage`, зависимость `.package(path: "../ZverTransport")` →
  таргет зависит от продукта `ZverTransport` (ради `Sha256`). БЕЗ внешних зависимостей.
- `protocol RemoteStore: Sendable` — асинхронный, абстрагирует облако (план Б S3 за тем же
  протоколом):
  ```
  func exists(path: String) async throws -> RemoteResource?           // nil = нет; иначе sha/size
  func list(folder: String) async throws -> [RemoteResource]
  func ensureFolder(path: String) async throws
  func upload(localFile: URL, to path: String,
              progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteResource
  func download(path: String, to localFile: URL, resumeFrom: Int64,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> RemoteResource
  func delete(path: String) async throws
  ```
  `RemoteResource { path, name, size: Int64, sha256: String?, isDir: Bool }`. Прогресс-замыкания
  `@Sendable` (приходят с сетевой очереди — потребитель сам прыгает на MainActor).
- `RemoteError`: `.unauthorized, .notFound, .conflict, .locked, .rateLimited(retryAfter: TimeInterval?),
  .insufficientStorage, .server(status: Int), .transport(underlying: Error), .badResponse` —
  `Sendable`. Это словарь ошибок для `RetryPolicy` (S4-3) и UI.
- `InMemoryRemoteStore` (актор или класс под `NSLock`, `@unchecked Sendable`): хранит
  `[path: (Data, sha256)]`; upload пишет, download читает (учитывая `resumeFrom`), exists/list/
  delete/ensureFolder — над словарём; считает sha через `ZverTransport.Sha256.hash(_:)`.
- TDD: upload→exists возвращает sha/size; download отдаёт те же байты; `resumeFrom` отдаёт хвост;
  delete убирает; list по папке; exists несуществующего → nil; модели round-trip Codable;
  `RemoteResource` сравнение. (Это база для TDD очереди в S4-4 — без сети.)

## S4-2: ZverStorage — Yandex wire: запросы и разбор ответов (чистое, TDD)

**Files:** Create `Sources/ZverStorage/Yandex/YandexRequestFactory.swift`
(сборка `URLRequest` для всех эндпоинтов раздела «Эндпоинты Яндекс REST», `app:/`-префикс,
percent-encoding `path`, заголовок `Authorization: OAuth`),
`Sources/ZverStorage/Yandex/YandexResponse.swift` (разбор JSON: `{href,method,templated}`,
`ResourceMeta`→`RemoteResource` с `_embedded.items`, статус операции, тело ошибки `{message,
description,error}`), `Sources/ZverStorage/Yandex/YandexError.swift` (маппинг HTTP-статус +
тело → `RemoteError`); Test `YandexRequestFactoryTests.swift`, `YandexResponseTests.swift`,
`YandexErrorTests.swift`.

- `YandexRequestFactory(baseURL:rootPrefix:)`: чистые методы `uploadHref(path:)`,
  `downloadHref(path:)`, `resourceMeta(path:fields:)`, `delete(path:permanently:)`,
  `createFolder(path:)`, `operationStatus(href:)`, `transfer(href:method:range:)` — каждый
  возвращает `URLRequest` (без выполнения). Токен подставляется отдельно (`authorized(_:token:)`),
  чтобы не светить его в фикстурах. `path` маппится в `app:/library/...` и percent-кодируется.
- `YandexResponse`: статические парсеры из `Data`. `parseHref` → `URL`; `parseResource` →
  `RemoteResource` (size/sha256/md5/type, директория по `type == "dir"`); `parseList` →
  `[RemoteResource]` из `_embedded.items`; `parseOperation` → enum `.inProgress/.success/.failed`.
- `YandexError.from(status:data:headers:)`: 401→`.unauthorized`, 404→`.notFound`, 409→`.conflict`,
  423→`.locked`, 429→`.rateLimited(retryAfter: <из Retry-After>)`, 507→`.insufficientStorage`,
  5xx→`.server`, прочее не-2xx→`.badResponse`.
- TDD: URL/метод/заголовки каждого реквеста (включая кодирование `path` с пробелами/кириллицей и
  `app:/`-префикс); разбор href; разбор ResourceMeta (файл и папка, с `sha256` и без); разбор
  списка; разбор статуса операции; маппинг всех ветвей ошибок + парс `Retry-After` (секунды и HTTP-дата).
  Фикстуры — строковые JSON-литералы в тестах (реальные формы ответов Яндекса из ресёрча).

## S4-3: ZverStorage — RetryPolicy: классификация и backoff (чистое, TDD)

**Files:** Create `Sources/ZverStorage/RetryPolicy.swift`; Test `RetryPolicyTests.swift`.

- `struct RetryPolicy { maxAttempts: Int (деф. 5); baseDelay: TimeInterval (деф. 1); maxDelay
  (деф. 60) }`. Методы: `isRetryable(_ error: RemoteError) -> Bool` (`rateLimited`/`locked`/
  `server`/`transport` → true; `unauthorized`/`notFound`/`conflict`/`insufficientStorage`/
  `badResponse` → false); `delay(forAttempt: Int, retryAfter: TimeInterval?) -> TimeInterval` —
  `min(maxDelay, baseDelay * 2^(attempt-1))`, но если задан `retryAfter` — `max(вычисленного,
  retryAfter)`. Детерминированно (без random jitter — чтобы TDD-ровать; jitter не нужен для
  личного приложения с ≤2 параллельных).
- TDD: ретраябельность каждой ошибки; экспонента 1→2→4→8→16, кламп на maxDelay; `Retry-After`
  перебивает короткую экспоненту, но не делает её меньше; `attempt > maxAttempts` → стоп
  (вызывающий проверяет `attempt <= maxAttempts`).

## S4-4: ZverStorage — TransferState и BackupQueue (чистое, TDD)

**Files:** Create `Sources/ZverStorage/Transfer/TransferState.swift`
(`enum TransferState { case queued; case requestingHref; case transferring(bytesSent: Int64);
case verifying; case done(RemoteResource); case failed(RemoteError, attempt: Int) }`,
`struct BackupItem { id: String; localFile: URL; remotePath: String; expectedSha: String?;
fileSize: Int64 }`), `Sources/ZverStorage/Transfer/BackupQueue.swift` (актор-планировщик
поверх инъецированных `RemoteStore` + `RetryPolicy` + `Sleeper` (протокол сна, fake-clock в
тестах)); Test `BackupQueueTests.swift`, `TransferStateTests.swift`.

- `BackupQueue` — НЕ сетевой: оркестрирует `RemoteStore`, держит ≤`maxConcurrent` (деф. 2)
  активных передач, упорядоченная FIFO с дедупом по `id`. Каждый элемент: `ensureFolder` →
  `upload` (с прогрессом) → `exists`/`upload`-результат даёт облачный sha → сверка с `expectedSha`
  (если задан) → `done`; при `RemoteError` — `RetryPolicy.isRetryable` + `delay` через `Sleeper`,
  до `maxAttempts`, иначе `failed`. Эмитит события (`@Sendable` колбэк или `AsyncStream`):
  `(itemId, TransferState)` — потребитель (S4-10) мапит в `fileState`.
- Аналогичный планировщик скачивания (`download` с `resumeFrom` из размера частичного файла,
  сверка sha) — либо общий `TransferQueue` с направлением `.upload/.download`, либо две роли в
  одном типе; решить по простоте при реализации, зафиксировать тестом.
- `Sleeper` протокол (`func sleep(_ seconds: TimeInterval) async`) — реальный (Task.sleep) и
  `FakeSleeper` (мгновенный, копит запрошенные задержки для проверки backoff) — чтобы TDD без
  реального ожидания.
- TDD (с `InMemoryRemoteStore` + `FakeSleeper`): очередь из N грузит по ≤2 параллельно; успех →
  `done` с облачным sha; сверка `expectedSha` несовпала → ретрай/фейл (зафиксировать поведение);
  `rateLimited(retryAfter:3)` → `FakeSleeper` получил ≥3с, затем успех; нерекаваемая ошибка
  (`unauthorized`) → немедленный `failed` без сна; дедуп повторного `id`; докачка с `resumeFrom`.

## S4-5: ZverStorage — YandexDiskStore: URLSession-адаптер (компиляция)

**Files:** Create `Sources/ZverStorage/Yandex/YandexDiskStore.swift` (реализует `RemoteStore`),
`Sources/ZverStorage/TokenProviding.swift` (`protocol TokenProviding: Sendable { func token()
async -> String? }` + `StaticTokenProvider`), `Sources/ZverStorage/Yandex/URLSessionHTTP.swift`
(тонкая обёртка `data(for:)`/фоновая загрузка, если нужно вынести).

- `YandexDiskStore(session: URLSession, factory: YandexRequestFactory, tokenProvider:
  TokenProviding, policy: RetryPolicy)`. Каждый метод: берёт токен → `factory` собирает запрос →
  `session` выполняет → `YandexResponse`/`YandexError` разбирают → при ретраябельной ошибке
  крутит `policy` (внутри метода или делегируя BackupQueue — НЕ дублировать backoff: low-level
  методы бросают `RemoteError`, ретраи живут в `BackupQueue`; здесь — одиночная попытка +
  маппинг ошибок). Двухэтапность: `upload`/`download` сперва берут href (`uploadHref`/
  `downloadHref`), затем PUT/GET на href. Скачивание — `Range: bytes=<resumeFrom>-`, дозапись в
  файл (зеркало `FileDownloader` этапа 3). Аплоад — PUT тела файла на href (резюм аплоада —
  best-effort: при обрыве заново запросить href и PUT; задокументировать как ограничение).
- Сессия — конфигурируемая; для переживания сворачивания приложения предусмотреть
  `URLSessionConfiguration.background(withIdentifier:)`-вариант; делегатские колбэки `@Sendable`,
  в UI — через `Task { @MainActor in }`. Это РАНТАЙМ-адаптер: тестами не покрываем, проверяем
  компиляцией; сеть проверяет владелец на устройстве.
- Проверка: `swift build` пакета зелёный; `swift test` пакета остаётся зелёным (адаптер не
  ломает чистые тесты). Никакого реального обращения к сети в тестах.

## S4-6: ZverStorage — YandexOAuth: authorize-URL и разбор redirect (TDD чистого)

**Files:** Create `Sources/ZverStorage/Auth/YandexOAuth.swift` (чистые хелперы),
`Sources/ZverStorage/Auth/WebAuthSession.swift` (`protocol WebAuthSession` + ЗАГОТОВКА адаптера
`ASWebAuthSession` под `#if canImport(AuthenticationServices)`, в MVP не активен);
Test `YandexOAuthTests.swift`.

- `YandexOAuth.authorizeURL(clientID:scope:redirectURI:state:) -> URL` (token-flow,
  `response_type=token`, scope `cloud_api:disk.app_folder`); `parseRedirect(_ url: URL) ->
  Result<String, OAuthError>` — достаёт `access_token` из fragment (`#access_token=...&expires_in=...`),
  ошибки (`error=access_denied`) → `.denied`/`.malformed`. Чистое, без сети/UI.
- `WebAuthSession` протокол: `func authenticate(url:callbackScheme:) async throws -> URL`. Адаптер
  на `ASWebAuthenticationSession` — заготовка (компилируется, помечен «требует client_id»),
  активируется позже. MVP-вход (ручной токен) живёт в app (S4-9), не зависит от этого.
- TDD: authorizeURL содержит верные query (client_id/scope/redirect/response_type/state);
  parseRedirect достаёт токен из fragment; `error=access_denied` → denied; мусорный redirect →
  malformed; токен с `&expires_in` парсится. `ASWebAuthSession`-адаптер не тестируем.

## S4-7: ZverCore — миграция v2, FileState, поля каталога (TDD)

**Files:** Modify `Sources/ZverCore/Catalog/Catalog.swift` (миграция `v2`),
`Sources/ZverCore/Catalog/TrackRecord.swift` (поля `fileState`, `cloudSha`),
`Sources/ZverCore/Track.swift` (поле `fileState`); Create
`Sources/ZverCore/Catalog/FileState.swift` (`enum FileState: String, Codable, Sendable` +
`canTransition(to:)`); Test `Tests/ZverCoreTests/FileStateTests.swift`, дополнить `CatalogTests.swift`.

- `FileState`: `case local, uploading, backedUp, remote, downloading` (rawValue — строки для БД).
  `var hasLocalFile: Bool` (true для всех кроме `remote`), `var isInCloud: Bool`
  (`backedUp`/`remote`), `func canTransition(to:) -> Bool` (рёбра графа из раздела «Жизненный цикл»).
- Миграция `v2`: `db.alter(table: "track")` добавляет `fileState TEXT NOT NULL DEFAULT 'local'`
  и `cloudSha TEXT` (nullable). Существующие строки получают `local` (они физически на диске).
  v1 не трогаем — миграции аддитивны и идемпотентны.
- `TrackRecord`: добавить `var fileState: String` (деф. `FileState.local.rawValue`) и
  `var cloudSha: String?`; протащить в оба `init` и в `track(documentsURL:)`. `Track`: добавить
  `var fileState: FileState` (деф. `.local`), протащить в `init` и в `TrackRecord.track(...)`.
  Маппинг сканера (`LibraryStore.record(from:)`) новые `local`-треки оставляет `local` —
  существующий вызов init с дефолтом, без правки сигнатуры скан-маппинга (поле опционально).
- TDD: миграция v2 на БД с v1-данными добавляет колонки, старые строки → `fileState == "local"`,
  `cloudSha == nil`; round-trip TrackRecord с `fileState`/`cloudSha`; `Track.fileState` дефолт
  `.local`; `canTransition` — валидные рёбра true, невалидные (`local→remote`, `remote→backedUp`,
  `local→downloading`) false; повторная миграция идемпотентна; СТАРЫЕ тесты каталога зелёные.

## S4-8: ZverCore — CatalogStore: апдейтеры состояния, reconcile-сохраняет-облако, restore (TDD)

**Files:** Modify `Sources/ZverCore/Catalog/CatalogStore.swift`; Test дополнить
`Tests/ZverCoreTests/CatalogStoreTests.swift`.

- Новые идемпотентные методы (синхронные, `dbQueue.write`):
  - `setFileState(relativePath:_ state: FileState, cloudSha: String? = nil)` — обновляет колонки
    одной строки; если `cloudSha` передан — пишет, иначе не трогает. Несуществующий путь — no-op.
  - `markBackedUp(relativePath:cloudSha:)` → `fileState = backedUp`, `cloudSha = …` (после сверки).
  - `tracksAwaitingBackup() -> [TrackRecord]` — `fileState == local` И `cloudSha IS NULL`
    (кандидаты на автобэкап).
  - `tracks(inState: FileState) -> [TrackRecord]` — для UI/диагностики.
  - `importRemoteCatalog(records: [TrackRecord])` — для восстановления: upsert записей из
    скачанного бэкапа как есть (они уже несут `cloudSha`); тем, у кого локального файла нет,
    выставить `fileState = remote`. Существующие локальные строки НЕ деградировать (если у нас
    уже `local`/`backedUp` — оставить; конфликт разрешаем в пользу «есть локально»).
- `reconcile`: правило удаления меняется (см. «Ключевое архитектурное решение»). Трек,
  отсутствующий в `scanned`, удаляется ТОЛЬКО если `НЕ облачный` (определяется чтением текущей
  строки: `cloudSha == nil` И `fileState ∈ {local, uploading}`) И `keepMissing(path) == false`.
  Облачные (`cloudSha != nil` ИЛИ `fileState ∈ {backedUp, remote, downloading}`) — сохраняются
  всегда. Upsert скана получает доп. `noOverwrite`: `[Column("addedAt"), Column("fileState"),
  Column("cloudSha")]` — скан не знает облачных полей и не должен их затирать на дефолты. (Для
  ВНОВЬ вставляемых строк дефолты берутся из значений TrackRecord: `local`/`nil`.)
- TDD (ключевые): (1) трек `remote` без файла на диске и без записи в `scanned` ПЕРЕЖИВАЕТ
  reconcile (не удалён); (2) трек `local` с пропавшим файлом и `keepMissing=false` — удалён, как
  раньше; (3) трек `backedUp`, файл на месте, в скане есть — upsert НЕ сбрасывает `fileState`/
  `cloudSha`/`addedAt`; (4) `setFileState`/`markBackedUp` идемпотентны (повтор не ломает);
  (5) `tracksAwaitingBackup` отбирает только `local`+`cloudSha==nil`; (6) `importRemoteCatalog`
  создаёт `remote`-записи и не деградирует существующие локальные; (7) СТАРЫЕ тесты reconcile
  (этап 2) остаются зелёными (поведение для чисто локальных треков не изменилось).

## S4-9: ZverIOS — аккаунт, Keychain-токен, экран Настроек, ZverStorage в проект (компиляция)

**Files:** Modify `Apps/ZverIOS/project.yml` (пакет+зависимость `ZverStorage`);
Create `Apps/ZverIOS/Sources/Cloud/CloudAccount.swift` (`@MainActor` ObservableObject: статус
залогинен/нет, сохранение/чтение/удаление токена через `KeychainKeyStore(account:
"zver-yandex-token")`, сервис-ключ `"yandex.disk"`; предоставляет `TokenProviding` для стора),
`Sources/Cloud/SettingsView.swift` (поле ввода токена + «Войти»/«Выйти», статус аккаунта,
заглушки переключателей автобэкапа — провод в S4-10/11); Modify `ContentView.swift` (4-я вкладка
«Облако»/«Настройки» ИЛИ пункт в Библиотеке — решить минимально; добавить вкладку с
`SettingsView`).

- `CloudAccount`: `login(token:)` валидирует непустоту, кладёт в Keychain, ставит `isAuthorized`;
  `logout()` удаляет; на старте читает токен (есть → авторизован). `tokenProvider` →
  `StaticTokenProvider` поверх прочитанного токена (обновляется при login/logout). НЕ хранит
  токен в `@Published`-строке открытым дольше необходимого (показывать маскированно).
- `project.yml`: добавить `ZverStorage: path: ../../Packages/ZverStorage` в `packages` и
  `- package: ZverStorage` в `dependencies` ZverIOS. Никаких новых Info.plist-ключей для ручного
  токена не нужно (HTTPS к Яндексу разрешён ATS по умолчанию). НЕ менять bundle id/DEVELOPMENT_TEAM.
- Проверка: `xcodegen generate` + `xcodebuild ... -destination "generic/platform=iOS Simulator"
  -derivedDataPath /tmp/zver-dd-ios CODE_SIGNING_ALLOWED=NO build` зелёный.

## S4-10: ZverIOS — BackupService: связка очереди, фон.сессия, переходы fileState (компиляция)

**Files:** Create `Apps/ZverIOS/Sources/Cloud/BackupService.swift` (`@MainActor`
ObservableObject), `Sources/Cloud/CloudPaths.swift` (маппинг `Track`/relativePath ↔ удалённый
`library/<albumId>/<fileName>` и `catalog.sqlite.backup`); Modify `CloudAccount.swift`/
`ContentView.swift` (инстанцировать сервис, прокинуть `CatalogStore`).

- `BackupService(catalogStore:documentsURL:store: RemoteStore = YandexDiskStore(...)
  tokenProvider:)`: строит `BackupQueue` (из S4-4) поверх `YandexDiskStore` (фоновая URLSession).
  Поток автобэкапа: после импорта/рескана берёт `catalogStore.tracksAwaitingBackup()` → строит
  `BackupItem` (локальный URL, remotePath, ожидаемый локальный sha через `Sha256.hash(fileURL:)`)
  → ставит в очередь. На событиях очереди: `transferring` → `setFileState(.uploading)`;
  `done(resource)` → сверка `resource.sha256 == локальный sha` → `markBackedUp(cloudSha:)`;
  `failed` → откат в `local` + лог в needs-attention (для UI-индикации ошибки). Бэкап каталога:
  после батча — `upload(localFile: catalog.sqlite, to: "catalog.sqlite.backup")` (перезапись).
- Скачивание (для S4-11 «Скачать»): метод `download(track:)` → `setFileState(.downloading)` →
  `YandexDiskStore.download(resumeFrom: размерЧастичного)` в staging → сверка sha → атомарный
  `moveItem` в `Documents/Library/...` (зеркало `DownloadEngine`) → `markBackedUp`/`local`(?) —
  после скачивания трек снова `backedUp` (на диске И в облаке) → рескан/republish.
- Offload (для S4-11 «Выгрузить»): `offload(track:)` разрешён ТОЛЬКО если `fileState == backedUp`
  И `cloudSha` подтверждён → удалить локальный файл → `setFileState(.remote)`. Гейт: повторно
  сверить наличие в облаке (`store.exists` sha) перед удалением — «удаление только при
  подтверждённом checksum».
- Замыкания в URLSession/очередь — `@Sendable`, переходы в UI/каталог — через `Task { @MainActor
  in }`/детач на фон для записи БД (как в `LibraryStore`). Это app-glue: проверка компиляцией.
- Проверка: компиляция iOS-таргета (как S4-9).

## S4-11: ZverIOS — UI статуса облака, действия, восстановление (компиляция)

**Files:** Create `Apps/ZverIOS/Sources/Cloud/TrackCloudBadge.swift` (иконка по `track.fileState`:
`backedUp`→☁️✓, `remote`→☁️, `uploading`→↑прогресс, `downloading`→↓прогресс, `local`→пусто),
`Sources/Cloud/RestoreView.swift` (кнопка «Восстановить из облака»: скачать
`catalog.sqlite.backup` → `importRemoteCatalog` → republish); Modify `Library/SongsView.swift`,
`Library/AlbumDetailView.swift` (бейдж в `trackRow` рядом с `TrackFormatBadge`; контекст-меню/
swipe «Выгрузить» (если `backedUp`) и «Скачать» (если `remote`)), `Library/LibraryStore.swift`
(проброс `fileState` уже идёт через `Track`; добавить методы-обёртки `offload(track:)`/
`download(track:)`, дёргающие `BackupService` и republish), `Cloud/SettingsView.swift`
(переключатель «Автобэкап новых альбомов», кнопка «Сделать бэкап каталога», вход в `RestoreView`).

- Бейдж — отдельный маленький `View` по образцу `TrackFormatBadge` (этап 2/3): читает
  `track.fileState`, не дёргает сеть. Действия — через `LibraryStore`→`BackupService` (async),
  с оптимистичным переходом состояния и republish после.
- Воспроизведение `remote`-трека: тап играет как раньше для `local`/`backedUp`/`downloading`(если
  файл на месте); для `remote` (файла нет) — НЕ падать: показать «Скачать» (плеер этапа 1 не
  трогаем; авто-докачка-перед-проигрыванием — в бэклог). Зафиксировать: ряд `remote`-трека ведёт
  на «Скачать», а не в проигрывание.
- Восстановление: `RestoreView` (в Настройках) — при авторизованном аккаунте: скачать каталог-
  бэкап во временный файл → открыть как `Catalog` → прочитать все `TrackRecord` →
  `catalogStore.importRemoteCatalog(records:)` → `library.refresh()`/republish. Вся библиотека
  показывается как ☁️ `remote`, дальше пользователь качает нужное.
- Проверка: компиляция iOS-таргета. UI smoke не гоняем (нет рантайма).

## S4-12: Финальный прогон и документация

**Files:** Modify `README.md`, `docs/manual-test-checklist.md`.

- `swift test` зелёный во ВСЕХ пакетах: `ZverCore`, `ZverMetadata`, `ZverTransport`, `ZverStorage`.
- `xcodegen generate` + компиляция ОБОИХ таргетов: ZverIOS (`generic/platform=iOS Simulator`,
  `-derivedDataPath /tmp/zver-dd-ios`, `CODE_SIGNING_ALLOWED=NO`) и **ZverMac** (`platform=macOS`,
  `-derivedDataPath /tmp/zver-dd-mac`, `CODE_SIGNING_ALLOWED=NO`) — Mac-guard: миграция v2 ZverCore
  не должна сломать Mac-таргет. Перед билдом — дождаться чистоты `Packages/`.
- README: новый блок «Этап 4 «Яндекс.Диск»» (storage за `RemoteStore`, `YandexDiskStore`, очередь
  бэкапа, `fileState`-жизненный цикл, ручной токен/Keychain, выгрузка/скачивание/восстановление),
  структура (+ `Packages/ZverStorage`), заметка про OAuth «решим позже».
- `docs/manual-test-checklist.md`: секция «Этап 4» — ручная проверка у владельца на устройстве:
  вставка токена → авторизация; новый альбом автобэкапится (☁️✓ появляется); «Выгрузить» удаляет
  локальный файл и ставит ☁️ (только после подтверждённого sha); «Скачать» возвращает файл и
  играет; обрыв сети на середине аплоада/докачки → продолжение/ретрай с backoff; 429 не валит
  очередь; удаление локального файла НЕ происходит без подтверждённого checksum; восстановление:
  переустановка → вход → «Восстановить из облака» → вся библиотека ☁️ → скачать нужное играет;
  ZverMac по-прежнему запускается и раздаёт (не сломан миграцией).

## Definition of Done

`swift test` зелёные в `ZverCore`/`ZverMetadata`/`ZverTransport`/`ZverStorage`; ОБА таргета
(ZverIOS, ZverMac) компилируются (`CODE_SIGNING_ALLOWED=NO`); README + manual-test-checklist
дополнены секцией этапа 4. Минорные замечания ревьюеров — в бэклог-отчёт, не чинить вне скоупа.
Ветка `stage4` запушена, PR в `main` открыт (НЕ смёржен). Ручная проверка облака — у владельца
на устройстве. Дальше — этап 5 «Пульт».

## Вне скоупа / бэклог (зафиксировано)

- Полноценный `ASWebAuthenticationSession`-вход (нужен зарегистрированный Яндекс-`client_id`) —
  заготовка есть, активация позже («решим потом»).
- Авто-докачка `remote`-трека перед проигрыванием (тап `remote` → «Скачать», плеер не трогаем).
- Резюмируемый аплоад на Яндекс (Content-Range на PUT) — best-effort, при обрыве перезапрос href
  и повтор PUT; докачка СКАЧИВАНИЯ (Range на GET) — полноценная.
- Авто-выгрузка давно не слушанного (дизайн «Отложено») — не делаем.
- План Б — Yandex Object Storage (S3) — НЕ реализуем; абстракция `RemoteStore` его допускает.
