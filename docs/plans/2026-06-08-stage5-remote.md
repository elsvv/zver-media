# Zver Media — Этап 5 «Пульт с Мака»: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: исполнение через dynamic workflow (конвейер
> имплементер → спек-ревью ∥ код-ревью качества → фикс-луп ≤2 круга), параллельные
> цепочки по графу зависимостей. Дисциплина параллельных агентов в одном репозитории:
> `git add` только своих путей (НИКОГДА `-A`), retry на `index.lock` (2с ×5), никаких
> `reset/checkout/stash`; задачи внутри одного SPM-пакета/таргета — последовательно
> (общий `.build`/DerivedData); перед билдом таргетов — дождаться чистоты `Packages/`
> (цикл `git status --porcelain Packages/` пуст, sleep 30, до 20 раз). Код-ревьюер —
> ДЕФОЛТНЫЙ workflow-агент (без `agentType:`), наследует Opus; null от ревьюера →
> needs-attention, а не тихий pass. Ревьюеры смотрят РЕАЛЬНЫЙ дифф файлов своей задачи
> (`git diff`/`git show` по путям), не доверяя слепо диапазону `baseSha..headSha`.

**Goal:** Пульт управления плеером iPhone с Мака по локальной сети. iPhone — WebSocket-
СЕРВЕР (тот же Bonjour `_zver._tcp`, переиспользуя анонс из ZverTransport), живёт пока
играет background audio; Mac — клиент. Версионируемый протокол: команды транспорта
(`play`/`pause`/`togglePlayPause`/`next`/`previous`/`seek`) + **браузинг библиотеки и запуск
альбома** (`requestLibrary`/`requestAlbumTracks`/`playAlbum`), пуш состояния (трек, позиция,
очередь, статус) при изменении. Два режима паузы (настройка): «всегда на связи» (на паузе —
тишина нулевыми сэмплами, приложение не усыпляется, ЦАП захвачен, команды доходят) и
«экономный» (на паузе приложение засыпает, пульт оживает с локскрина). `MPRemoteCommandCenter`
этапа 1 не ломаем. ZverMac: окно «Пульт» (текущий трек, транспорт, очередь, браузинг
библиотеки), деградация «iPhone не в сети». Pairing/доверие — переиспользуем механизм этапа 3
(роли перевёрнуты: **iPhone — хост pairing**).

**Architecture.** Роли сети ПЕРЕВЁРНУТЫ относительно этапа 3 (там Mac — хост/сервер, iPhone —
клиент): теперь **iPhone advertises + WebSocket-сервер + pairing-хост**, **Mac browses +
WebSocket-клиент + pairing-клиент**. Чистая логика — в `ZverTransport`; рантайм-сетевые
объекты — за протоколами.

1. **`ZverTransport` — протокол пульта (чистое, TDD):** версионируемый конверт `RemoteMessage`
   (как `SyncManifest.protocolVersion`), команды `RemoteCommand`, состояние `RemotePlayerState`,
   библиотека `RemoteLibrary`/`RemoteAlbum`/`RemoteTrack` (DTO протокола, БЕЗ зависимости от
   `ZverCore.Track` — как `ManifestTrack` этапа 3), сообщения pairing/hello. `RemoteCodec` —
   encode/decode JSON, версия, forward-compat (неизвестные ключи/версия). Пара pure-хелперов:
   состояние-диф (пушим только при изменении, троттлинг позиции) и проверка hello-токена.

2. **`ZverTransport` — WebSocket-адаптеры за протоколами (рантайм, компиляция):**
   `WebSocketServing` (+ `NWWebSocketServer` на `NWListener` + `NWProtocolWebSocket`, iOS-сервер)
   и `WebSocketClient` (+ `NWWebSocketClient` на `NWConnection` + `NWProtocolWebSocket`, Mac-клиент);
   шлют/принимают `RemoteMessage` текстовыми фреймами. Тонкие непокрытые адаптеры (лессон:
   рантайм-сеть за протоколами). Замыкания `@Sendable`, переходы в UI/плеер — `Task { @MainActor }`.

3. **`ZverTransport` — Bonjour-роль (чистое + адаптер):** `DiscoveredService` получает TXT-поля;
   `ServiceBrowser` пробрасывает TXT; чистый фильтр по роли (`svc=remote` vs `svc=sync`), чтобы Mac
   не путал пульт-сервис iPhone с синк-сервисом Мака (один и тот же `_zver._tcp`). Отсутствие
   `svc` трактуется как `sync` — поведение этапа 3 не меняется.

**iOS (`ZverIOS`):** `RemoteControlService` (@MainActor) — поднимает WS-сервер (advertise
`_zver._tcp` TXT `svc=remote`), pairing-хост (показ кода, выпуск токена в Keychain), авторизация
соединения по `hello{token}`, приём команд → `PlayerEngine` (транспорт) и → `LibraryStore`
(`playAlbum`/библиотека), наблюдение `PlayerEngine` (`@Published state/queue/currentTime`) → пуш
`RemotePlayerState` при изменении. Плюс **режимы паузы**: настройка + silent keep-alive в
`PlayerEngine` для «всегда на связи». Экран Настроек: вкл. пульта, режим паузы, код сопряжения,
статус подключения. `NowPlayingService`/`MPRemoteCommandCenter` — НЕ ломать (команды пульта и
системные команды оба идут в `PlayerEngine`, сосуществуют).

**ZverMac:** `RemoteClientCoordinator` (@MainActor) — browse `svc=remote`, pairing-клиент (ввод
кода с iPhone → токен в Keychain), WS-подключение, `hello{token}`, отправка команд, приём
состояния/библиотеки; окно «Пульт» `RemoteControlView` (текущий трек + транспорт + очередь +
браузинг альбомов → запуск), деградация «iPhone не в сети».

**Решение по аутентификации (зафиксировано).** Pairing и авторизация идут ПОВЕРХ WebSocket
(до приёма команд): новый Mac шлёт `pair{code}` (код показан на iPhone) → iPhone сверяет
(`Pairing.verify`, константное время) → `paired{token}`, Mac кладёт токен в Keychain. Дальше при
каждом подключении Mac шлёт `hello{token}` первым сообщением → iPhone сверяет с выпущенным токеном
→ `helloAck` и только потом принимает команды/шлёт состояние. Переиспользуем `Pairing` (генерация
кода/токена, сверка) и `KeychainKeyStore` из этапа 3; роли перевёрнуты (iPhone выпускает токен).
Один доверенный Mac в MVP (токен под сервис-ключом `zver-remote`).

**Решение по библиотеке (скоуп — транспорт + браузинг, выбран владельцем).** Mac браузит
библиотеку iPhone и запускает альбомы. Чтобы не слать всю (большую) библиотеку зараз: на коннект
iPhone шлёт лёгкий список альбомов (`RemoteLibrary` — id/title/artist/year/trackCount), Mac по
запросу тянет треки альбома (`requestAlbumTracks(albumId)` → `albumTracks(albumId, [RemoteTrack])`);
`playAlbum(albumId, startIndex)` — iPhone резолвит альбом из своего каталога (`AlbumGroup`) и зовёт
`PlayerEngine.play(tracks:startAt:)`. Mac никогда не получает локальные URL/файлы. `remote`-треки
этапа 4 (без локальной копии) при playAlbum плеер пропустит — авто-докачка-перед-проигрыванием в
бэклог.

**Решение по сетевому стеку (зафиксировано):** `Network.framework` + `NWProtocolWebSocket`
(а не URLSession WebSocket): iPhone обязан быть СЕРВЕРОМ (`NWListener`), URLSession сервер не умеет;
симметрично клиент — `NWConnection`. Зеркало паттерна `FileServer`/`MacSyncClient` этапа 3, только
роли перевёрнуты и application-protocol = WebSocket.

**Tech Stack:** + системный `Network` (`NWProtocolWebSocket`), `CryptoKit`/`Security` (переиспользование
`Pairing`/`KeyStore`), `AVAudioEngine` (silent keep-alive — только iOS, в app-таргете). Новых внешних
SPM-зависимостей НЕТ. Local Network privacy-ключи (`NSLocalNetworkUsageDescription` +
`NSBonjourServices: [_zver._tcp]`) и `UIBackgroundModes: [audio]` уже есть в обоих `project.yml`
с этапа 3 — проверить/переиспользовать, не дублировать.

**Контекст:** дизайн — `docs/plans/2026-06-06-zver-cloud-design.md`, раздел «Пульт с Мака» (выжимка
ресёрча: пока играет background audio, сокеты живы → Mac управляет по WebSocket, задержки мс; на
паузе приложение суспендится → обход тишиной; MPRemoteCommandCenter обязателен — подтверждено Apple
DTS). Повторный веб-ресёрч не нужен. Этапы 1–4 завершены и в `main` (плеер+ЦАП+gapless+
MPRemoteCommandCenter; каталог GRDB; синк Mac→iPhone через ZverTransport Bonjour/pairing; Яндекс.Диск).
Окружение: Xcode 26.4.1, Swift 6.3.1, симрантаймов/девайсов нет — таргеты ТОЛЬКО компилируются
(`CODE_SIGNING_ALLOWED=NO`), `xcodebuild test`/`simctl`/`devicectl` ЗАПРЕЩЕНЫ; `swift test` пакетов
как обычно. Переиспользуем: `ZverTransport` (`ServiceAdvertiser`/`ServiceBrowser`/`_zver._tcp`,
`Pairing`/`PairingMessages`/`KeychainKeyStore`, версионирование `SyncManifest`), `PlayerEngine`
(`play`/`pause`/`resume`/`next`/`previous`/`seek`, `@Published state/queue/currentTime`),
`PlaybackQueue` (Codable/Sendable), `AlbumGroup`, паттерны `NWListener` (`FileServer`/`ServerCoordinator`)
и `NWConnection` (`MacSyncClient` с `ContinuationBox`).

## Протокол пульта (фиксируется в S5-1, версия 1)

```
Конверт: RemoteMessage { protocolVersion: Int, payload: RemotePayload }
RemotePayload (oneOf, тег "type"):
  Mac → iPhone (команды/запросы):
    pair            { code }                       // до авторизации
    hello           { token }                      // первое сообщение при наличии токена
    play | pause | togglePlayPause | next | previous
    seek            { seconds: Double }
    requestLibrary
    requestAlbumTracks { albumId }
    playAlbum       { albumId, startIndex: Int }
  iPhone → Mac (ответы/пуш):
    paired          { token }                      // ответ на pair при верном коде
    helloAck        { ok: Bool, protocolVersion }  // ответ на hello
    state           { RemotePlayerState }          // пуш при изменении (троттлинг позиции)
    library         { RemoteLibrary }              // на коннект и при изменении каталога
    albumTracks     { albumId, tracks: [RemoteTrack] }
    error           { message }
RemotePlayerState { playback: "idle"|"playing"|"paused", current: RemoteTrack?,
                    position: Double, queue: [RemoteTrack], currentIndex: Int? }
RemoteTrack { id, title, artist?, album?, duration, sampleRate?, bitDepth? }
RemoteAlbum { id, title, artist?, year?, trackCount }
RemoteLibrary { albums: [RemoteAlbum] }
Bonjour: тип _zver._tcp, TXT: name=<имя iPhone>, v=1, svc=remote
```

Все типы `Codable, Equatable, Sendable`. `RemoteMessage.currentProtocolVersion = 1`. Декод с
неизвестными ключами/payload-type не падает (forward-compat); чужая версия доступна вызывающему.

## Граф исполнения

```
Цепочка T (ZverTransport, внутри пакета — последовательно, общий .build):
  S5-1 протокол+кодек (чистое, TDD)
  → S5-2 Bonjour-роль: TXT в DiscoveredService + фильтр svc (чистое TDD + адаптер компиляция)
  → S5-3 WebSocket-адаптеры (WebSocketServing/Client + NW* реализации) [компиляция]
Затем (T готов, чистота Packages/), ДВЕ ПАРАЛЛЕЛЬНЫЕ цепочки (разные таргеты):
├─ iOS:  S5-4 RemoteControlService (сервер+pairing-хост+авторизация+команды+пуш+библиотека)
│        → S5-5 режимы паузы + silent keep-alive в PlayerEngine
│        → S5-6 Настройки/UI пульта на iPhone (вкл., режим, код, статус)
└─ Mac:  S5-7 RemoteClientCoordinator (browse+pairing-клиент+WS+команды+приём состояния)
         → S5-8 окно «Пульт»: транспорт + очередь + браузинг библиотеки + деградация
Финал: S5-9 swift test всех пакетов + компиляция ОБОИХ таргетов + README + чеклист
```

---

## S5-1: ZverTransport — протокол пульта и кодек (TDD)

**Files:** Create `Sources/ZverTransport/Remote/RemoteMessage.swift` (`RemoteMessage` конверт +
`RemotePayload` enum по схеме), `Sources/ZverTransport/Remote/RemoteModels.swift`
(`RemotePlayerState`, `RemoteTrack`, `RemoteAlbum`, `RemoteLibrary`), `Sources/ZverTransport/Remote/RemoteCodec.swift`
(encode `RemoteMessage`→`Data`, decode `Data`→`RemoteMessage`; `decodeVersion` для проверки версии),
`Sources/ZverTransport/Remote/RemoteStateDiff.swift` (чистый троттлер/диф: эмитить state только при
значимом изменении — смена трека/playback/очереди ИЛИ сдвиг позиции > порога);
Test `Tests/ZverTransportTests/RemoteMessageTests.swift`, `RemoteCodecTests.swift`, `RemoteStateDiffTests.swift`.

- `RemotePayload` — enum со всеми вариантами схемы, Codable через тег `type` (ручной
  `init(from:)`/`encode(to:)` или `enum` с `CodingKeys`). `RemoteMessage.currentProtocolVersion = 1`,
  `protocolVersion` — явное поле.
- `RemoteCodec`: JSON encode/decode; неизвестный `type` → вариант `.unknown`/бросок, который НЕ
  роняет соединение (вызывающий игнорирует); декод манифеста чужой версии — успешно, версия доступна.
- `RemoteStateDiff`: `shouldEmit(prev:next:positionThreshold:) -> Bool` — true при смене
  playback/current/queue/currentIndex; для позиции — только если |Δ| ≥ threshold (напр. 0.5с), чтобы
  не флудить пушами каждые 0.5с (позицию Mac может интерполировать сам).
- TDD: round-trip каждого варианта payload (pair/hello/play/seek/playAlbum/requestAlbumTracks/
  paired/helloAck/state/library/albumTracks/error); версия сериализуется и читается; неизвестный
  `type` не роняет декод; `RemoteStateDiff` эмитит на смене трека/очереди/playback и на сдвиге
  позиции ≥ порога, молчит на микросдвиге.

## S5-2: ZverTransport — Bonjour-роль: TXT в DiscoveredService + фильтр (TDD + компиляция)

**Files:** Modify `Sources/ZverTransport/Discovery/ServiceBrowser.swift`
(`DiscoveredService` + поле `txt: [String: String]`; `NWServiceBrowser` извлекает TXT из
`NWBrowser.Result.metadata` и кладёт в сервис), `Sources/ZverTransport/Discovery/DiscoveredServiceRegistry.swift`
(хранит txt; фильтр); Create `Sources/ZverTransport/Discovery/ServiceRole.swift` (константы
`ServiceTXT.roleKey = "svc"`, `.remote = "remote"`, `.sync = "sync"`; `DiscoveredService.role`
вычисляемое: `txt["svc"] ?? "sync"`); Test дополнить `DiscoveredServiceRegistryTests.swift`,
Create `ServiceRoleTests.swift`.

- `DiscoveredService` получает `txt` (дефолт `[:]` — обратная совместимость вызовов этапа 3).
  Регистр дедуплицирует/сортирует как раньше; добавить `services(role:)` — фильтр по `svc`
  (отсутствие `svc` → `sync`).
- `NWServiceBrowser`: при резолве результата прочитать `NWTXTRecord` из `result.metadata`
  (`case .bonjour(let txt)`), сериализовать в `[String:String]`. Адаптер — компиляция; чистый
  фильтр/реестр — TDD.
- ВАЖНО: НЕ сломать этап 3 — `ServiceBrowser.start(onChange:)` сигнатура прежняя; `svc` отсутствует
  у Mac-синк-сервиса (или добавить `svc=sync` в его анонс в S5-7? — НЕТ, чтобы не трогать чужой
  таргет в этой задаче: фильтр трактует отсутствие как `sync`).
- TDD: `services(role: .remote)` отбирает только `svc=remote`; отсутствие `svc` → роль `sync`;
  дедуп/сортировка с txt сохраняются; пустой txt у старых сервисов не ломает реестр.

## S5-3: ZverTransport — WebSocket-адаптеры за протоколами (компиляция)

**Files:** Create `Sources/ZverTransport/Remote/WebSocketServing.swift` (протокол сервера:
`start(port:name:txt:onClient:) / send(RemoteMessage, to: ClientID) / broadcast(RemoteMessage) / stop()`,
`onClient` отдаёт хэндл соединения + поток входящих `RemoteMessage`), `NWWebSocketServer.swift`
(`NWListener` + `NWParameters` с `NWProtocolWebSocket.Options` как application-protocol; на коннект —
приём текстовых фреймов → `RemoteCodec.decode`; отправка — `RemoteCodec.encode` + `NWProtocolWebSocket.Metadata(opcode: .text)`),
`Sources/ZverTransport/Remote/WebSocketClient.swift` (протокол клиента:
`connect(to: DiscoveredService, onMessage:, onState:) / send(RemoteMessage) / disconnect()`),
`NWWebSocketClient.swift` (`NWConnection` к Bonjour-endpoint с `NWProtocolWebSocket`, receive-loop →
decode, send → encode; `ContinuationBox`-подобная защита одного резюма по образцу `MacSyncClient`).

- Оба адаптера — РАНТАЙМ, тестами не покрываем (лессон). Замыкания, передаваемые в `NWListener`/
  `NWConnection`, — `@Sendable`, НЕ наследуют `@MainActor`; переходы в плеер/UI — `Task { @MainActor in }`.
  Состояние соединений под `NSLock`/актором, `@unchecked Sendable` где оправдано.
- Сервер раздаёт `ClientID` на каждое соединение; держит соединения, чтобы `broadcast` слал всем
  авторизованным. Авторизация (hello/pair) — НЕ в адаптере, а в app-слое (S5-4): адаптер лишь
  возит `RemoteMessage`.
- Проверка: `swift build`/`swift test` пакета остаются зелёными (адаптеры компилируются, чистые
  тесты S5-1/S5-2 не трогаются). Сетевую часть проверяет владелец на железе.

## S5-4: ZverIOS — RemoteControlService: сервер, pairing-хост, команды, пуш, библиотека (компиляция)

**Files:** Create `Apps/ZverIOS/Sources/Remote/RemoteControlService.swift` (@MainActor
ObservableObject), `Sources/Remote/RemoteLibraryBuilder.swift` (маппинг `LibraryStore.albums`
(`[AlbumGroup]`) → `RemoteLibrary`/`albumTracks`; резолв `albumId`+`startIndex` → `[Track]` для
`playAlbum`), `Sources/Remote/RemotePairingHost.swift` (генерация/показ кода, сверка `Pairing.verify`,
выпуск токена в `KeychainKeyStore(account:"zver-remote-token")`, сервис `zver-remote`); Modify
`ZverIOSApp.swift`/`ContentView.swift` (инстанцировать сервис с `PlayerEngine`+`LibraryStore`).

- Сервис поднимает `NWWebSocketServer`, advertises `_zver._tcp` TXT `{name, v:"1", svc:"remote"}`.
  На соединение: ждёт `hello{token}` (сверка с выпущенным) ИЛИ `pair{code}` (сверка кода → `paired{token}`);
  до авторизации команды игнорируются. После авторизации: шлёт `library` + текущий `state`; принимает
  команды → `PlayerEngine` (`play`→resume, `pause`, `togglePlayPause`, `next`, `previous`, `seek`),
  `requestLibrary`/`requestAlbumTracks`/`playAlbum` → через `RemoteLibraryBuilder`+`LibraryStore`.
- Наблюдение `PlayerEngine.$state/$queue/$currentTime` (Combine) → строит `RemotePlayerState` →
  `RemoteStateDiff.shouldEmit` → `broadcast(state)`. Очередь сериализуется как `[RemoteTrack]`.
- Жизненный цикл: сервер запущен, пока включён пульт И жив background audio (играет или «всегда на
  связи»). Замыкания сети `@Sendable` → `Task { @MainActor in }`. НЕ трогать `NowPlayingService`.
- Проверка: компиляция iOS-таргета (`xcodegen` + `xcodebuild ... CODE_SIGNING_ALLOWED=NO`).

## S5-5: ZverIOS — режимы паузы + silent keep-alive (компиляция)

**Files:** Create `Apps/ZverIOS/Sources/Audio/KeepAlivePlayer.swift` (отдельный
`AVAudioPlayerNode` + зацикленный буфер тишины, привязанный к `engine`), `Sources/Audio/PauseMode.swift`
(`enum PauseMode { case alwaysConnected, economical }`, persist в `UserDefaults`); Modify
`Sources/Audio/PlayerEngine.swift` (поле `pauseMode`; в `pause()` при `.alwaysConnected` —
запустить keep-alive тишину (приложение не усыпляется, сессия активна, ЦАП захвачен), при
`.economical` — текущее поведение; в `resume()`/`loadAndPlay` — остановить keep-alive).

- Silent keep-alive: маленький буфер нулевых сэмплов формата текущего графа, `scheduleBuffer(...,
  .loops)` на ОТДЕЛЬНОЙ ноде (не основной `player`, чтобы не мешать gapless-бухгалтерии и позиции).
  На паузе в `.alwaysConnected`: основной `player.pause()` (позиция сохраняется), keep-alive играет
  тишину → iOS держит приложение живым → WS-сервер обслуживает команды. На `resume`/смене трека/seek —
  keep-alive стоп. Аккуратно с пересбором графа (`rebuildGraph`/route change): keep-alive переаттачить.
- НЕ ломать: gapless (`prescheduleNext`/`sampleTimeBase`), `currentTime`, `MPRemoteCommandCenter`,
  обработку route/interruption. Чистая часть (решение «нужен ли keep-alive» по `pauseMode`+`state`) —
  маленький TDD-тест на `PauseMode`/decision, если выносимо без AVAudioEngine; сам keep-alive —
  компиляция (рантайм аудио, проверяет владелец).
- Краш-класс Swift 6: никаких новых замыканий в системные API из `@MainActor` без `@Sendable`.
- Проверка: компиляция iOS-таргета.

## S5-6: ZverIOS — Настройки и UI пульта на iPhone (компиляция)

**Files:** Create `Apps/ZverIOS/Sources/Remote/RemoteSettingsView.swift` (тумблер «Пульт с Мака»,
пикер режима паузы, кнопка «Показать код сопряжения» → 6-значный код + окно ожидания, статус
«Mac подключён»/«нет»); Modify `Sources/ContentView.swift` или существующий экран Настроек этапа 4
(`Cloud/SettingsView.swift` — добавить секцию «Пульт», НЕ дублировать вкладку) — решить минимально и
зафиксировать.

- UI читает/пишет `RemoteControlService` (вкл/выкл сервера, текущий код сопряжения, число
  подключённых Маков, режим паузы). Код показывается по запросу, на ограниченное окно сопряжения.
- Местоположение: добавить «Пульт» в существующий экран Настроек (этап 4 завёл `SettingsView` во
  вкладке «Облако»/«Настройки») — переименовать вкладку в «Настройки», секции «Облако» и «Пульт».
  Не плодить вкладки.
- Проверка: компиляция iOS-таргета. Local Network privacy + background audio ключи — проверить, что
  уже есть в `project.yml` (этап 3), НЕ дублировать.

## S5-7: ZverMac — RemoteClientCoordinator: browse, pairing-клиент, WS, приём состояния (компиляция)

**Files:** Create `Apps/ZverMac/Sources/Remote/RemoteClientCoordinator.swift` (@MainActor
ObservableObject: статус `idle/discovering/discovered/pairing/connected(state)/offline`),
`Sources/Remote/RemotePairingClient.swift` (отправка `pair{code}` → приём `paired{token}` → Keychain),
`Sources/Remote/RemoteClientStore.swift` (агрегатор принятого `RemotePlayerState`/`RemoteLibrary`/
`albumTracks` для UI). Использует `NWWebSocketClient` + `NWServiceBrowser` (фильтр `svc=remote`) из
ZverTransport.

- Поток: browse `_zver._tcp` (`services(role:.remote)`) → выбор iPhone → если есть токен в Keychain
  (`KeychainKeyStore(account:"zver-remote-token")`, сервис = имя iPhone) → WS-connect → `hello{token}`;
  иначе → ввод кода с iPhone → `pair{code}` → `paired{token}` сохранить → `hello`. После `helloAck` —
  приём `library`/`state`/`albumTracks`, отправка команд.
- Деградация: соединение упало/iPhone пропал из browse → статус `offline` («iPhone не в сети»),
  переподключение при возврате. Замыкания сети `@Sendable` → `Task { @MainActor in }`. Зеркало
  `ServerCoordinator`/`MacSyncClient` этапа 3 (роли перевёрнуты).
- Проверка: компиляция macOS-таргета (`xcodegen` + `xcodebuild -scheme ZverMac ... CODE_SIGNING_ALLOWED=NO`).

## S5-8: ZverMac — окно «Пульт»: транспорт, очередь, браузинг библиотеки (компиляция)

**Files:** Create `Apps/ZverMac/Sources/Remote/RemoteControlView.swift` (текущий трек: title/artist/
album/позиция + транспорт play-pause-next-prev + слайдер seek; очередь; статус подключения),
`Sources/Remote/RemoteLibraryView.swift` (список `RemoteAlbum` → по тапу `requestAlbumTracks` →
список `RemoteTrack` → `playAlbum(albumId,startIndex)`); Modify `Sources/ZverMacApp.swift` (новое
`Window("Пульт", id:"remote")` + пункт в `MenuBarExtra` «Открыть пульт»).

- `RemoteControlView` биндится к `RemoteClientCoordinator`: транспорт-кнопки шлют команды, слайдер
  позиции — `seek`; состояние (трек/позиция/playback/очередь) из принятого `RemotePlayerState`
  (позицию между пушами интерполировать таймером по `playback==playing`). Деградация «iPhone не в
  сети» — заглушка с кнопкой переподключения.
- `RemoteLibraryView`: альбомы из `RemoteLibrary`; раскрытие альбома тянет треки; запуск — `playAlbum`.
- Проверка: компиляция macOS-таргета. Реальное управление — владелец на железе (iPhone+Mac в одной сети).

## S5-9: Финальный прогон и документация

**Files:** Modify `README.md`, `docs/manual-test-checklist.md`.

- `swift test` зелёный во ВСЕХ пакетах (`ZverCore`, `ZverMetadata`, `ZverTransport`, `ZverStorage`).
- `xcodegen generate` + компиляция ОБОИХ таргетов: ZverIOS (`generic/platform=iOS Simulator`,
  `-derivedDataPath /tmp/zver-dd-ios`, `CODE_SIGNING_ALLOWED=NO`) и ZverMac (`platform=macOS`,
  `-derivedDataPath /tmp/zver-dd-mac`, `CODE_SIGNING_ALLOWED=NO`). Перед билдом — дождаться чистоты `Packages/`.
- README: блок «Этап 5 «Пульт»» (iPhone — WS-сервер, Mac — клиент/окно пульта, протокол,
  pairing с перевёрнутыми ролями, два режима паузы, браузинг библиотеки), структура (+ Remote/ в
  обоих приложениях, Remote/ в ZverTransport).
- `docs/manual-test-checklist.md`: секция «Этап 5» — ручная проверка у владельца (iPhone+Mac в одной
  сети): включить пульт на iPhone; Mac находит iPhone, сопряжение кодом (первый раз); транспорт
  (play/pause/seek/next/prev) с Мака мгновенно меняет воспроизведение; смена трека/позиции на iPhone
  отражается в окне пульта; браузинг библиотеки на Маке, запуск альбома; режим «всегда на связи» —
  команды доходят и на паузе; режим «экономный» — на паузе пульт слепнет, оживает с локскрина;
  iPhone ушёл из сети → «iPhone не в сети», возврат → переподключение; локскрин/Control Center
  (MPRemoteCommandCenter) по-прежнему работают.

## Definition of Done

`swift test` зелёные в `ZverCore`/`ZverMetadata`/`ZverTransport`/`ZverStorage`; ОБА таргета
(ZverIOS, ZverMac) компилируются (`CODE_SIGNING_ALLOWED=NO`); README + manual-test-checklist
дополнены секцией этапа 5. Минорные замечания ревьюеров — в бэклог-отчёт, не чинить вне скоупа.
Ветка `stage5` запушена, PR в `main` открыт (НЕ смёржен). Ручная проверка пульта — у владельца на
железе. Это последний этап MVP (1–5).

## Вне скоупа / бэклог (зафиксировано)

- Авто-докачка `remote`-трека (этап 4) перед `playAlbum`, если у альбома нет локальных файлов
  (сейчас плеер пропустит отсутствующие).
- Несколько одновременных Маков-пультов (MVP — один доверенный токен).
- Пуш обложек в пульт (Mac показывает текст; артворк — бэклог).
- On-demand против полного пуша библиотеки доведён до album-list + album-tracks; стриминг/пагинация
  очень больших каталогов — бэклог.
- Управление громкостью/shuffle/repeat с пульта — бэклог (вне команд MVP).
