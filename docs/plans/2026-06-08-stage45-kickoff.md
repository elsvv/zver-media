# Kickoff-промпт для нового чата — этапы 4 и 5 Zver Media

> Этот файл — заготовка. Открой НОВЫЙ чат Claude Code в этом репозитории
> (модель Opus 4.8, по желанию `/effort ultracode`) и вставь блок ниже целиком.
> Файл не закоммичен — это памятка, делай с ним что хочешь.

---

# Zver Media — этапы 4 «Яндекс.Диск» и 5 «Пульт»: продолжение разработки

Ты продолжаешь разработку проекта Zver Media (https://github.com/elsvv/zver-media) —
личная медиасистема: lossless/hi-res iOS-плеер с выводом на USB ЦАП + Mac-компаньон +
Яндекс.Диск как холодный ярус. Рабочая директория — корень клона. Этапы 1–3 готовы
(плеер+ЦАП, каталог GRDB, плейлисты, gapless; синк Mac→iPhone: ZverTransport, ZverMac,
импорт с докачкой). Этап 3 лежит в PR #1 (ветка `stage3`).

## Сначала прочитай (в этом порядке)
1. `docs/plans/2026-06-06-zver-cloud-design.md` — дизайн системы. Разделы «Яндекс.Диск»
   (этап 4) и «Пульт с Мака» (этап 5) — это твой скоуп. Там же выжимка ресёрча
   (REST API Яндекса, WebDAV троттлится, двухэтапный upload/download по временным href,
   Content-Range, app-folder, OAuth, backoff на 429; пульт через WebSocket пока играет
   background audio, два режима паузы, MPRemoteCommandCenter). Повторный веб-ресёрч не нужен.
2. `docs/plans/2026-06-07-stage2-catalog-library.md` и `docs/plans/2026-06-07-stage3-mac-sync.md`
   — формат планов этапов (повтори его). И `docs/plans/2026-06-08-stage3-smart-artwork.md`.
3. README.md и код: `Packages/ZverCore` (Track/Catalog GRDB/fileState/плейлисты),
   `Packages/ZverMetadata`, `Packages/ZverTransport` (манифест/SHA-256/pairing/Bonjour
   `_zver._tcp`/HTTP — этап 5 переиспользует Bonjour и pairing отсюда!),
   `Apps/ZverIOS`, `Apps/ZverMac`.

## Ветки и порядок
- Этап 4 НЕЗАВИСИМ от транспорта (это storage-слой). Этап 5 ОПИРАЕТСЯ на ZverTransport
  из этапа 3 (тот же `_zver._tcp` Bonjour + pairing/Keychain).
- Поэтому: если PR #1 (stage3) ещё НЕ смёржен — ветви `stage4` от `stage3`. Если смёржен —
  от `main`. Спроси/уточни перед стартом. `main` не трогать, пушить только свою ветку,
  открыть PR (не мёржить сам). По одному PR на этап (stage4, затем stage5).
- Делай этап 4 ПОЛНОСТЬЮ (план → workflow → своя верификация → пуш → PR), затем этап 5.

## Скоуп этапа 4 «Яндекс.Диск» (из дизайна)
- `Packages/ZverStorage` (новый SPM, iOS 17/macOS 14): протокол `RemoteStore`
  (upload/download/list/delete/exists) + реализация `YandexDiskStore` — свой тонкий клиент
  на URLSession (~6 эндпоинтов REST). Сетевые рантайм-объекты за протоколом, чистая логика
  (модель состояний передачи, очередь бэкапа, парсинг ответов, backoff) — TDD без сети.
- OAuth: `ASWebAuthenticationSession` или отладочный токен (~год), хранить в Keychain
  (переиспользуй паттерн KeyStore из ZverTransport, не дублируй слепо — оцени).
- fileState в каталоге (`local`/`remote`/`downloading`/`uploading` + backed-up): жизненный
  цикл из дизайна, идемпотентные транзакции, checksum (SHA-256 из ZverTransport) сверяется
  после каждой передачи. Удаление локальной копии — ТОЛЬКО при подтверждённом checksum в облаке.
- Очередь бэкапа: новый альбом → background URLSession, 2 параллельных файла, двухэтапная схема
  (запрос href прямо перед стартом — href живёт 30 мин), докачка Content-Range, ретраи с
  exponential backoff на 429, 2–4 параллельных передачи максимум.
- iOS UI: статус ☁️ в рядах треков, «Выгрузить»/«Скачать», восстановление (логин → скачать
  каталог → вся библиотека в облаке → качать нужное).
- Storage СТРОГО за протоколом `RemoteStore` (план Б — Yandex Object Storage S3, не делать,
  но абстракция должна позволять).

## Скоуп этапа 5 «Пульт с Мака» (из дизайна)
- iPhone — WebSocket-СЕРВЕР (тот же `_zver._tcp`, переиспользуй Bonjour-анонс из ZverTransport),
  Mac — клиент. Живёт, пока играет background audio.
- Протокол (в ZverTransport, версионируемый): команды (`play`, `pause`, `seek:<s>`,
  `next`, `prev`, `playAlbum:<id>`, …) и состояние (трек, позиция, очередь — пуш при изменении).
  Сетевые объекты за протоколами, протокол/состояния — TDD.
- Два режима паузы (настройка): «всегда на связи» (на паузе тишина — нулевые сэмплы, ЦАП
  захвачен, команды доходят) и «экономный» (приложение засыпает). MPRemoteCommandCenter
  уже есть с этапа 1 — не ломать.
- ZverMac: окно пульта (текущий трек, транспорт, очередь), деградация «iPhone не в сети».
- pairing/доверие — переиспользовать механизм этапа 3.

## Окружение этой машины (ВАЖНО)
- Xcode 26.4.1, Swift 6.3.1, `xcodegen` установлен. СИМУЛЯТОРНЫХ РАНТАЙМОВ И ДЕВАЙСОВ НЕТ,
  Apple ID чужой.
- Пакеты: `swift test --package-path Packages/<имя>` работает как обычно.
- Приложения — ТОЛЬКО компиляция (изолируй DerivedData per-target):
  - iOS: `xcodegen generate --spec Apps/ZverIOS/project.yml --project Apps/ZverIOS && \
    xcodebuild -project Apps/ZverIOS/ZverIOS.xcodeproj -scheme ZverIOS \
    -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/zver-dd-ios \
    CODE_SIGNING_ALLOWED=NO build`
  - Mac: `xcodegen generate --spec Apps/ZverMac/project.yml --project Apps/ZverMac && \
    xcodebuild -project Apps/ZverMac/ZverMac.xcodeproj -scheme ZverMac \
    -destination "platform=macOS" -derivedDataPath /tmp/zver-dd-mac CODE_SIGNING_ALLOWED=NO build`
- ЗАПРЕЩЕНО: simctl, xcodebuild test (нет рантайма), devicectl, -downloadPlatform; менять
  bundle id `dev.zver.ZverIOS`/`dev.zver.ZverMac` и DEVELOPMENT_TEAM (6RWCS65D85) в project.yml.

## Процесс (обязательный)
1. На КАЖДЫЙ этап напиши план `docs/plans/<дата>-stage4-yandex.md` /
   `...-stage5-remote.md` по формату плана этапа 3: задачи S4-1..S4-N (S5-…) с
   файлами/шагами/TDD, граф параллельных/последовательных цепочек. Вопросы по
   неоднозначностям задавай ДО старта. ПОКАЖИ план секциями, дождись «ок», закоммить, потом workflow.
2. Исполняй через dynamic **Workflow**, конвейер на каждую задачу:
   - имплементер (TDD в пакетах; structured output: blocked, report, baseSha, headSha, commits[], verification);
   - затем ПАРАЛЛЕЛЬНО два ревью: спек-ревьюер (перезапускает тесты/билды САМ, смотрит дифф
     задачи через git diff/show) и код-ревьюер качества (читает диффы, БЕЗ xcodebuild;
     вердикт approved/critical/important/minor);
   - замечания обоих → один фикс-агент → повторное ревью только упавших измерений; максимум
     2 фикс-круга, иначе стоп и отчёт. Ревьюеры блокируют баги/расхождения со спекой, не стиль.
   - минорное — в бэклог-отчёт, не чинить молча вне скоупа.
3. Дисциплина параллельных агентов в одном дереве: коммить ТОЛЬКО свои пути
   (`git add -- <пути>` + `git commit -m … -- <пути>`, НИКОГДА `-A`), retry на index.lock
   (2с×5), никаких reset/checkout/stash. Задачи внутри одного SPM-пакета — ПОСЛЕДОВАТЕЛЬНО
   (общий .build); разные пакеты/приложения — параллельно. Перед билдом таргетов — дождаться
   чистоты `Packages/` (цикл git status --porcelain Packages/ пуст, sleep 30, до 20 раз).
4. Коммиты feat:/fix:/test:/docs: на русском; последняя строка каждого —
   `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
5. ПОСЛЕ workflow — НЕ доверяй отчёту: САМ прогони `swift test` всех пакетов и компиляцию
   ОБОИХ таргетов. Потом запушь ветку и открой PR (`gh pr create`, base main/stage3),
   НЕ мёржи. PR-боди заверши строкой `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## КРИТИЧНЫЕ УРОКИ ПРЕДЫДУЩЕЙ СЕССИИ (не повторить)
- **`superpowers:code-reviewer` НЕ СУЩЕСТВУЕТ.** В superpowers только скиллы, агентов нет;
  code-reviewer лежит в других плагинах, которые в этой сессии НЕ резолвятся как subagent_type.
  Для код-ревью в Workflow используй ДЕФОЛТНОГО workflow-агента (БЕЗ `agentType:` — он наследует
  Opus), а не кастомный тип. Иначе все код-ревью-агенты молча умирают, и задачи «одобряются»
  по одному спек-ревью. Добавь страховку: если ревьюер вернул null — это в бэклог/needs-attention,
  а не тихий pass.
- В shared-tree параллельных цепочках `git rev-parse HEAD` ловит ГЛОБАЛЬНЫЙ HEAD, поэтому
  baseSha..headSha у задачи могут быть смазаны (захватывать чужие коммиты). Велите ревьюерам
  смотреть РЕАЛЬНЫЙ дифф файлов своей задачи, а не слепо доверять диапазону.
- Swift 6 краш-класс: замыкания в системные/сетевые API (NWListener/NWBrowser/NWConnection,
  URLSession делегаты, NotificationCenter), вызываемые на фоновых очередях, НЕ должны
  наследовать @MainActor-изоляцию — помечай @Sendable, внутрь Task { @MainActor in … }.
- AVAudioSession только iOS — в SPM-пакеты не тащить (абстракции за протоколами).
- Сетевые рантайм-объекты (URLSession-загрузчики, WebSocket, NWListener) — за протоколами;
  чистая логика (очередь бэкапа, протокол пульта, состояния передачи, парсинг) — TDD без сети.
- Диагностики SourceKit вида «No such module Testing» / «Cannot find type X» в новых файлах —
  это ШУМ LSP без билд-контекста (xcodeproj не сгенерён / пакет не собран), НЕ реальные ошибки.
  Истина — `swift test` и `xcodebuild`.
- Не забудь Local Network privacy ключи (NSLocalNetworkUsageDescription + NSBonjourServices)
  для WebSocket-сервера этапа 5 — они уже есть в обоих project.yml с этапа 3, проверь/переиспользуй.

## Definition of Done (на каждый этап)
- Все новые/затронутые пакеты `swift test` зелёные; ОБА таргета компилируются
  (CODE_SIGNING_ALLOWED=NO); README + docs/manual-test-checklist.md дополнены секцией этапа
  (ручная проверка у владельца — на железе). Ветка запушена, PR открыт, в main не смёржен.

Начинай с этапа 4: прочитай документы, уточни ветку (от stage3 или main), напиши план,
покажи секциями, дождись «ок», запускай workflow. Потом этап 5.
