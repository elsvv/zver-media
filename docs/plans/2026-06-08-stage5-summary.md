# Этап 5 «Пульт с Мака» — итоги сессии

**Дата:** 2026-06-08 · **Ветка:** `stage5` · **PR:** [#3 в `main`](https://github.com/elsvv/zver-media/pull/3) (открыт, не смёржен) · **Статус:** последний этап MVP, ждёт ручной проверки на железе

---

## Что делали

Реализовали удалённое управление плеером iPhone с Мака по локальной сети. **iPhone — WebSocket-СЕРВЕР** (тот же Bonjour `_zver._tcp`, переиспользует анонс из `ZverTransport`), живёт пока играет background audio; **Mac — клиент** с окном «Пульт». Роли сети перевёрнуты относительно этапа 3 (там Mac был хостом/сервером). Версионируемый протокол: транспорт (`play`/`pause`/`togglePlayPause`/`next`/`previous`/`seek`) + браузинг библиотеки и запуск альбома (`requestLibrary`/`requestAlbumTracks`/`playAlbum`), пуш состояния при изменении. `MPRemoteCommandCenter` этапа 1 не тронут.

## Как делали

Запустили заранее написанный multi-agent workflow (`docs/plans/stage5-workflow.js`, run `wf_175931fe-1ff`): 9 задач, конвейер **имплементер → спек-ревью ∥ качество-ревью → фикс-луп ≤2 круга**, граф зависимостей — цепочка `ZverTransport` → параллельно `iOS` ∥ `Mac` → финал.

**Результат оркестрации:** 9/9 задач `approved`, **0 фикс-кругов, 0 needs-attention/blocked**. 27 агентов, ~49 мин.

## Что вошло (14 коммитов на `stage5` поверх `main`)

| Задача | Слой | Содержание |
|--------|------|------------|
| **S5-1** | ZverTransport (TDD) | Протокол пульта: `RemoteMessage` (версионируемый конверт) + `RemotePayload` + DTO (`RemotePlayerState`/`RemoteTrack`/`RemoteAlbum`/`RemoteLibrary`) + `RemoteCodec` (JSON, forward-compat) + `RemoteStateDiff` (троттлинг пушей) |
| **S5-2** | ZverTransport (TDD) | Bonjour-роль: `txt:[String:String]` в `DiscoveredService` (обратно совместимо с этапом 3), `ServiceRole` (`svc=remote`/`sync`), фильтр `services(role:)` |
| **S5-3** | ZverTransport | WebSocket-адаптеры за протоколами: `WebSocketServing`/`NWWebSocketServer` (`NWListener`), `WebSocketClient`/`NWWebSocketClient` (`NWConnection`), `NWProtocolWebSocket` |
| **S5-4** | iOS | `RemoteControlService`: WS-сервер, advertise `svc=remote`, pairing-хост (токен в Keychain), авторизация `hello`/`pair`, команды → `PlayerEngine`, библиотека → `LibraryStore` |
| **S5-5** | iOS | Режимы паузы: `PauseMode {alwaysConnected, economical}` + `KeepAlivePlayer` (зацикленная тишина). Gapless/`currentTime`/`MPRemoteCommandCenter` не тронуты |
| **S5-6** | iOS | Секция «Пульт» в Настройках: тумблер, пикер режима паузы, код сопряжения, статус |
| **S5-7** | Mac | `RemoteClientCoordinator`: browse `services(role:.remote)`, pairing-клиент, WS, приём состояния, деградация «iPhone не в сети» + переподключение |
| **S5-8** | Mac | Окно «Пульт»: трек + транспорт + слайдер seek + очередь + браузинг библиотеки → запуск альбома; `Window("Пульт")` + пункт в `MenuBarExtra` |
| **S5-9** | Docs | README + `docs/manual-test-checklist.md` секция «Этап 5» |

## Независимая верификация (не доверяя отчёту оркестрации)

- `swift test` ×4 пакета → **423 теста зелёные**: ZverCore 80, ZverMetadata 37, ZverTransport 167, ZverStorage 139.
- `xcodebuild` (`CODE_SIGNING_ALLOWED=NO`): **ZverIOS** (`generic/platform=iOS Simulator`) → BUILD SUCCEEDED; **ZverMac** (`platform=macOS`) → BUILD SUCCEEDED.
- Рабочее дерево чистое, осиротевших файлов работы агентов нет.

## Реальный баг, найденный и починенный поверх оркестрации

**`6154e47` — `fix: S5-7 epoch-guard`** (отдельный fix-коммит, ZverMac перекомпилирован):

> При `select()`/`reconnect()` к уже подключённому iPhone возникала гонка. `NWWebSocketClient.connect()` первым делом синхронно `disconnect()`-ит старую сессию, та шлёт терминальный `onState(.disconnected)`. Проверка колбэка только по имени устройства недостаточна (имя совпадает) — устаревший `.disconnected` проходил guard и через `goOffline()` рвал только что поднятую новую сессию того же iPhone (пульт уходил в offline вместо connected).
>
> **Фикс:** монотонный `sessionGeneration` (epoch-guard) — `connect`/`goOffline`/`stop` инкрементят его, колбэки клиента захватывают своё поколение, обработчики (`handleConnectionState`/`handleIncoming`) отбрасывают хвосты устаревшей/заменённой сессии.

Остальные 44 минорных замечания ревью — косметика, осознанные решения по спеке или недостижимые на практике пути → вынесены в бэклог PR, вне скоупа не чинились.

## Бэклог (на потом)

- Протокол: `RemotePayload.unknown`/`RemotePlayback.unknown` при ре-сериализации теряют тело/исходную строку (безопасно — кодек сам такие кадры не порождает).
- S5-3: нет лимита размера входящего фрейма (`maximumMessageSize`) и активного ping-liveness (отложено в app-слой).
- S5-4: `playAlbum`/`requestAlbumTracks` по исчезнувшему `albumId` отдают пусто, а не `error{message}`.
- S5-5: `KeepAlivePlayer.reattach(format:)` — мёртвый код, док-комментарий вводит в заблуждение; нет unit-теста на чистый `needsKeepAliveOnPause` (в ZverIOS нет unit-таргета).
- S5-6: смена режима паузы mid-pause применится лишь со следующей паузы; неиспользуемый `import ZverTransport`.
- S5-7: нет backoff при флапающем сервере; нет `deinit`.
- S5-8: кнопка «Сопрячь» активна при ≥4 символах (код 6-значный); токен/выбор по имени устройства (один доверенный Mac в MVP).
- Вне скоупа MVP: авто-докачка `remote`-трека этапа 4 перед `playAlbum`; несколько одновременных Маков-пультов; пуш обложек в пульт; пагинация очень больших каталогов; громкость/shuffle/repeat с пульта.

## Что осталось

**Ручная проверка пульта на железе** (iPhone + Mac в одной сети) по секции «Этап 5» в `docs/manual-test-checklist.md`: включить пульт, сопряжение кодом, транспорт/seek с Мака, отражение смены трека/позиции, браузинг библиотеки и запуск альбома, оба режима паузы, деградация «iPhone не в сети» → возврат, и что локскрин/Control Center (`MPRemoteCommandCenter`) по-прежнему работают.

Как чек-лист пройден и PR #3 смёржен — **MVP (этапы 1–5) полностью готов**.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
