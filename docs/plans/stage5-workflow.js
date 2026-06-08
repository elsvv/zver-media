export const meta = {
  name: 'zver-stage5-remote',
  description: 'Этап 5 Zver Media «Пульт с Мака»: ZverTransport (протокол пульта/WebSocket/Bonjour-роль), iOS WS-сервер + режимы паузы + UI, ZverMac окно пульта — конвейер имплементер→(спек∥качество)ревью→фикс по 9 задачам',
  phases: [
    { title: 'ZverTransport' },
    { title: 'iOS' },
    { title: 'Mac' },
    { title: 'Финал' },
  ],
}

// ─────────────────────────────── общие блоки промптов ───────────────────────────────

const ENV = [
  'Рабочая директория — корень репозитория Zver Media (git), ты уже в ней. Ветка: stage5 (НЕ трогай main, НЕ переключай ветку).',
  'Окружение: macOS, Xcode 26.4.1, Swift 6.3.1. СИМУЛЯТОРНЫХ РАНТАЙМОВ И ДЕВАЙСОВ НЕТ.',
  '- Пакеты SPM проверяются: swift test --package-path Packages/<имя> (работает как обычно).',
  '- Приложения (Apps/ZverIOS, Apps/ZverMac) проверяются ТОЛЬКО КОМПИЛЯЦИЕЙ (CODE_SIGNING_ALLOWED=NO). ЗАПРЕЩЕНО: simctl, xcodebuild test, devicectl, -downloadPlatform.',
  'УРОКИ Swift 6 (соблюдай строго):',
  '- Замыкания в системные/сетевые API (NWListener/NWConnection/NWBrowser, URLSession-делегаты, NotificationCenter, Task на фоновых очередях) НЕ должны наследовать @MainActor-изоляцию: помечай @Sendable, переходы в UI/плеер — внутрь Task { @MainActor in ... }.',
  '- Сетевые рантайм-объекты (NWWebSocketServer/Client, NWListener, NWConnection) — за протоколами; чистая логика (протокол/кодек пульта, диф состояния, фильтр Bonjour-роли, проверка токена) — TDD без сети.',
  '- AVAudioSession/AVAudioEngine — только iOS, в SPM-пакеты не тащить (silent keep-alive живёт в app-таргете ZverIOS).',
  '- Диагностики SourceKit («No such module», «Cannot find type») в новых файлах без билд-контекста — ШУМ LSP, НЕ реальные ошибки. Истина — swift test / xcodebuild.',
  'Не выходи за рамки своей задачи: постороннее/минорное — в backlog-поле отчёта, не чини молча. Не трогай файлы других задач. Не меняй bundle id (dev.zver.*) и DEVELOPMENT_TEAM (6RWCS65D85). НЕ ломай этап 1 (MPRemoteCommandCenter/NowPlayingService, gapless) и этапы 3–4 (синк, облако).',
].join('\n')

const COMMIT = [
  'ДИСЦИПЛИНА КОММИТОВ (критично — параллельные агенты в одном дереве):',
  '- Коммить ТОЛЬКО свои пути: git add -- <пути> && git commit -m "<msg>" -- <пути>. НИКОГДА не используй -A, -u, ".", или git add без явных -- путей.',
  '- При ошибке index.lock — sleep 2 и повтори, до 5 раз.',
  '- ЗАПРЕЩЕНО: git reset, git checkout <file>, git stash, git rebase, git merge — любые операции, трогающие чужие изменения.',
  '- Сгенерированные .xcodeproj (Apps/*/*.xcodeproj) в .gitignore — НЕ коммить их. project.yml и Info.plist — коммить.',
  '- Сообщения на русском, префиксы feat:/fix:/test:/docs:. ПОСЛЕДНЯЯ строка каждого коммита ровно:',
  '  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>',
  'TDD (задачи в пакетах): сперва падающий тест (red), затем реализация (green); коммить тест и реализацию (можно раздельно test: затем feat:).',
].join('\n')

const PLAN = 'docs/plans/2026-06-08-stage5-remote.md'

const WAIT_PKGS = 'Перед xcodebuild дождись чистоты Packages/: for i in $(seq 1 20); do [ -z "$(git status --porcelain Packages/)" ] && break; sleep 30; done'

function implPrompt(t) {
  return [
    'Ты — ИМПЛЕМЕНТЕР задачи ' + t.id + ' этапа 5 «Пульт с Мака» проекта Zver Media.',
    ENV,
    COMMIT,
    'ТВОЯ ЗАДАЧА (' + t.id + '): ' + t.title,
    'Суть: ' + t.summary,
    'АВТОРИТЕТНАЯ СПЕЦИФИКАЦИЯ: прочитай ' + PLAN + ' и найди секцию, начинающуюся со строки "## ' + t.id + ':". Реализуй её ПОЛНОСТЬЮ. Также прочитай в том же файле шапку (архитектура и зафиксированные решения) и раздел «Протокол пульта». Изучи переиспользуемый код: Packages/ZverTransport (Discovery/ServiceAdvertiser+ServiceBrowser+DiscoveredServiceRegistry, Pairing/*, Manifest/SyncManifest версионирование), Apps/ZverIOS/Sources/Audio/PlayerEngine.swift и NowPlayingService.swift, Apps/ZverMac/Sources/Net/FileServer.swift+ServerCoordinator.swift, Apps/ZverIOS/Sources/Import/MacSyncClient.swift (ContinuationBox-паттерн) — чтобы повторить стиль и не дублировать.',
    (t.kind === 'package' ? 'Это задача в SPM-пакете — веди TDD (red→green).' : 'Это задача в приложении (' + (t.target || '') + ') — проверяется компиляцией (рантайм-тестов нет).'),
    'ТВОИ ПУТИ ДЛЯ КОММИТА: ' + t.paths.join(' '),
    'ВЕРИФИКАЦИЯ (прогони сам, добейся зелёного ДО завершения):',
    (t.kind === 'app' ? WAIT_PKGS + '\n' : '') + t.verify,
    'Закоммить работу (только свои пути). Верни структурированный отчёт: blocked (true только если ГЕНУИННО заблокирован отсутствующим API из другой задачи — опиши blockedReason, не переимплементируй чужое), report, filesChanged, commits (хэши/сабджекты), verification (что прогнал и результат), testsGreen, backlog (отложенное минорное).',
  ].join('\n\n')
}

function specPrompt(t) {
  return [
    'Ты — СПЕК-РЕВЬЮЕР задачи ' + t.id + ' этапа 5 проекта Zver Media. Цель — поймать БАГИ и РАСХОЖДЕНИЯ СО СПЕКОЙ; стиль не блокируй.',
    ENV,
    'НИЧЕГО НЕ КОММИТЬ и не менять файлы — только ревью и перезапуск верификации.',
    'СПЕКА — контракт задачи: прочитай ' + PLAN + ', секцию "## ' + t.id + ':" (и связанные разделы шапки + «Протокол пульта»).',
    'Смотри РЕАЛЬНЫЙ дифф файлов задачи (НЕ доверяй диапазону sha — в общем дереве он смазан чужими коммитами): git log --oneline -- ' + t.paths.join(' ') + ' ; git show <commit> -- ' + t.paths.join(' ') + ' ; читай актуальное содержимое файлов.',
    'ПЕРЕЗАПУСТИ ВЕРИФИКАЦИЮ САМ и убедись, что зелёная:',
    (t.kind === 'app' ? WAIT_PKGS + '\n' : '') + t.verify,
    'Блокируй (severity critical/important), если: тесты/сборка падают; поведение расходится со спекой; реальный баг (неверный кодек/версионирование протокола, неверный диф/троттлинг состояния, неверный фильтр Bonjour-роли ломает этап 3, неверная авторизация pairing/hello, утечка/незавершённый continuation в WS-адаптере, неверная конкурентность или @MainActor-наследование в @Sendable-колбэках сети, поломка MPRemoteCommandCenter/gapless/keep-alive ломает паузу). Мелочи/стиль — в minorFindings (backlog), НЕ блокируй. approved=true только если верификация зелёная и спека выполнена. Заполни dimension="spec" и ranVerification реальным результатом прогона.',
  ].join('\n\n')
}

function qualPrompt(t) {
  return [
    'Ты — КОД-РЕВЬЮЕР КАЧЕСТВА задачи ' + t.id + ' этапа 5 проекта Zver Media. НЕ запускай xcodebuild и не пересобирай приложение — только читай код/диффы (swift test пакета — по желанию).',
    ENV,
    'НИЧЕГО НЕ КОММИТЬ и не менять файлы — только ревью.',
    'Контекст-спека: ' + PLAN + ', секция "## ' + t.id + ':".',
    'Читай РЕАЛЬНЫЙ дифф файлов задачи: git log --oneline -- ' + t.paths.join(' ') + ' ; git show <commit> -- ' + t.paths.join(' ') + ' ; читай содержимое.',
    'Ищи НАСТОЯЩИЕ проблемы качества/корректности: некорректная обработка ошибок; force-unwrap/precondition с риском краша; retain-циклы и утечки ресурсов (NWConnection/NWListener/continuations не резюмятся ровно один раз); неверная Swift 6 конкурентность (@MainActor-наследование в @Sendable-колбэках, гонки, не-Sendable захваты, незакрытые continuations); поломка MPRemoteCommandCenter/gapless/обработки route-interruption при правке PlayerEngine; некорректный silent keep-alive (мешает позиции/gapless); неверная авторизация (приём команд до hello/pair); дублирование вместо переиспользования Pairing/KeyStore/ServiceBrowser. Вердикт: critical/important → blockingFindings; minor → minorFindings (backlog). dimension="quality". Блокируй только реальные баги/риски.',
  ].join('\n\n')
}

function fixPrompt(t, blocking) {
  return [
    'Ты — ФИКС-АГЕНТ задачи ' + t.id + ' этапа 5 проекта Zver Media. Исправь ТОЛЬКО перечисленные блокирующие замечания, не расширяя скоуп.',
    ENV,
    COMMIT,
    'СПЕКА: ' + PLAN + ', секция "## ' + t.id + ':".',
    'БЛОКИРУЮЩИЕ ЗАМЕЧАНИЯ РЕВЬЮ (JSON):',
    JSON.stringify(blocking, null, 2),
    'ТВОИ ПУТИ ДЛЯ КОММИТА: ' + t.paths.join(' '),
    'Исправь и перезапусти верификацию до зелёного:',
    (t.kind === 'app' ? WAIT_PKGS + '\n' : '') + t.verify,
    'Закоммить (только свои пути, префикс fix:). Верни отчёт: fixed, report, filesChanged, commits, verification, unresolved (что не удалось решить).',
  ].join('\n\n')
}

// ─────────────────────────────── схемы структурированного вывода ───────────────────────────────

const IMPL_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    taskId: { type: 'string' }, blocked: { type: 'boolean' }, blockedReason: { type: 'string' },
    report: { type: 'string' }, filesChanged: { type: 'array', items: { type: 'string' } },
    commits: { type: 'array', items: { type: 'string' } }, verification: { type: 'string' },
    testsGreen: { type: 'boolean' }, backlog: { type: 'string' },
  },
  required: ['taskId', 'blocked', 'report', 'filesChanged', 'commits', 'verification', 'testsGreen'],
}

const FINDING = {
  type: 'object', additionalProperties: false,
  properties: {
    severity: { type: 'string', enum: ['critical', 'important', 'minor'] },
    file: { type: 'string' }, description: { type: 'string' }, fix: { type: 'string' },
  },
  required: ['severity', 'description'],
}

const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    dimension: { type: 'string' }, approved: { type: 'boolean' }, ranVerification: { type: 'string' },
    blockingFindings: { type: 'array', items: FINDING }, minorFindings: { type: 'array', items: FINDING },
    summary: { type: 'string' },
  },
  required: ['dimension', 'approved', 'blockingFindings', 'summary'],
}

const FIX_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    fixed: { type: 'boolean' }, report: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } }, commits: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string' }, unresolved: { type: 'string' },
  },
  required: ['fixed', 'report', 'verification'],
}

// ─────────────────────────────── конвейер задачи ───────────────────────────────

function reviewerOutcome(r) {
  if (r === null) return { died: true, blocking: [], minor: [] }
  return { died: false, blocking: r.blockingFindings || [], minor: r.minorFindings || [] }
}

async function runReviews(t, dims, round) {
  const thunks = []
  if (dims.spec) thunks.push(() => agent(specPrompt(t), { label: 'spec:' + t.id + ':r' + round, phase: t.phase, schema: REVIEW_SCHEMA }))
  if (dims.quality) thunks.push(() => agent(qualPrompt(t), { label: 'qual:' + t.id + ':r' + round, phase: t.phase, schema: REVIEW_SCHEMA }))
  const res = await parallel(thunks)
  let i = 0
  const out = {}
  if (dims.spec) out.spec = res[i++]
  if (dims.quality) out.quality = res[i++]
  return out
}

async function runTask(t) {
  const impl = await agent(implPrompt(t), { label: 'impl:' + t.id, phase: t.phase, schema: IMPL_SCHEMA })
  if (!impl) return { id: t.id, title: t.title, status: 'needs-attention', reason: 'имплементер вернул null (умер)' }
  if (impl.blocked) return { id: t.id, title: t.title, status: 'blocked', reason: impl.blockedReason || 'blocked', impl }

  let dims = { spec: true, quality: true }
  let round = 0
  const allMinor = []
  let lastReviews = {}
  while (true) {
    const reviews = await runReviews(t, dims, round)
    lastReviews = Object.assign(lastReviews, reviews)
    const specOut = dims.spec ? reviewerOutcome(reviews.spec) : { died: false, blocking: [], minor: [] }
    const qualOut = dims.quality ? reviewerOutcome(reviews.quality) : { died: false, blocking: [], minor: [] }
    allMinor.push(...specOut.minor, ...qualOut.minor)
    const reviewerDied = specOut.died || qualOut.died
    const blocking = [...specOut.blocking, ...qualOut.blocking]

    if (blocking.length === 0 && !reviewerDied) {
      return { id: t.id, title: t.title, status: 'approved', round, impl, minor: allMinor, reviews: lastReviews }
    }
    if (round >= 2) {
      return {
        id: t.id, title: t.title, status: 'needs-attention', round,
        reason: reviewerDied ? 'ревьюер умер (null) — не считаем тихим pass' : 'блокирующие замечания не сняты за 2 фикс-круга',
        blocking, reviewerDied, impl, minor: allMinor, reviews: lastReviews,
      }
    }
    if (blocking.length > 0) {
      const fix = await agent(fixPrompt(t, blocking), { label: 'fix:' + t.id + ':r' + (round + 1), phase: t.phase, schema: FIX_SCHEMA })
      if (!fix) return { id: t.id, title: t.title, status: 'needs-attention', reason: 'фикс-агент умер (null)', blocking, impl, minor: allMinor }
      dims = { spec: true, quality: qualOut.blocking.length > 0 || qualOut.died }
    } else {
      dims = { spec: specOut.died, quality: qualOut.died }
    }
    round++
  }
}

async function runChain(tasks, label) {
  const results = []
  let blockedUpstream = false
  for (const t of tasks) {
    if (blockedUpstream) {
      results.push({ id: t.id, title: t.title, status: 'skipped', reason: 'предыдущая задача цепочки заблокирована' })
      log('[' + label + '] ' + t.id + ' ПРОПУЩЕНА (upstream blocked)')
      continue
    }
    log('[' + label + '] старт ' + t.id + ': ' + t.title)
    const r = await runTask(t)
    results.push(r)
    log('[' + label + '] ' + t.id + ' → ' + r.status + (r.round != null ? ' (раунд ' + r.round + ')' : ''))
    if (r.status === 'blocked') blockedUpstream = true
  }
  return results
}

// ─────────────────────────────── определения задач ───────────────────────────────

const V_TRANSPORT = 'swift test --package-path Packages/ZverTransport 2>&1 | tail -20'
const V_IOS = 'xcodegen generate --spec Apps/ZverIOS/project.yml --project Apps/ZverIOS && xcodebuild -project Apps/ZverIOS/ZverIOS.xcodeproj -scheme ZverIOS -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/zver-dd-ios CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -40'
const V_MAC = 'xcodegen generate --spec Apps/ZverMac/project.yml --project Apps/ZverMac && xcodebuild -project Apps/ZverMac/ZverMac.xcodeproj -scheme ZverMac -destination "platform=macOS" -derivedDataPath /tmp/zver-dd-mac CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -40'
const V_FINAL = [
  'swift test --package-path Packages/ZverCore 2>&1 | tail -3',
  'swift test --package-path Packages/ZverMetadata 2>&1 | tail -3',
  'swift test --package-path Packages/ZverTransport 2>&1 | tail -3',
  'swift test --package-path Packages/ZverStorage 2>&1 | tail -3',
  'xcodegen generate --spec Apps/ZverIOS/project.yml --project Apps/ZverIOS && xcodebuild -project Apps/ZverIOS/ZverIOS.xcodeproj -scheme ZverIOS -destination "generic/platform=iOS Simulator" -derivedDataPath /tmp/zver-dd-ios CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5',
  'xcodegen generate --spec Apps/ZverMac/project.yml --project Apps/ZverMac && xcodebuild -project Apps/ZverMac/ZverMac.xcodeproj -scheme ZverMac -destination "platform=macOS" -derivedDataPath /tmp/zver-dd-mac CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5',
].join('\n')

const TRANSPORT_TASKS = [
  { id: 'S5-1', phase: 'ZverTransport', kind: 'package', paths: ['Packages/ZverTransport'], verify: V_TRANSPORT,
    title: 'Протокол пульта и кодек (чистое, TDD)',
    summary: 'RemoteMessage (версионируемый конверт, как SyncManifest.protocolVersion) + RemotePayload (pair/hello/play/pause/togglePlayPause/next/previous/seek/requestLibrary/requestAlbumTracks/playAlbum; paired/helloAck/state/library/albumTracks/error) + DTO (RemotePlayerState/RemoteTrack/RemoteAlbum/RemoteLibrary) + RemoteCodec (encode/decode JSON, версия, forward-compat неизвестных type) + RemoteStateDiff (эмит state только при значимом изменении трека/playback/очереди или сдвиге позиции ≥ порога). Всё Codable/Equatable/Sendable. TDD round-trip всех вариантов, версия, неизвестный type не роняет декод, диф.' },
  { id: 'S5-2', phase: 'ZverTransport', kind: 'package', paths: ['Packages/ZverTransport'], verify: V_TRANSPORT,
    title: 'Bonjour-роль: TXT в DiscoveredService + фильтр svc (TDD + компиляция)',
    summary: 'DiscoveredService получает поле txt:[String:String] (дефолт [:], обратная совместимость этапа 3); NWServiceBrowser извлекает TXT из NWBrowser.Result.metadata; DiscoveredServiceRegistry хранит txt; ServiceRole (константы svc/remote/sync, DiscoveredService.role = txt["svc"] ?? "sync") + фильтр services(role:). Отсутствие svc → sync (этап 3 не ломается). TDD: services(role:.remote) отбирает только remote, отсутствие svc → sync, дедуп/сортировка с txt сохраняются.' },
  { id: 'S5-3', phase: 'ZverTransport', kind: 'package', paths: ['Packages/ZverTransport'], verify: V_TRANSPORT,
    title: 'WebSocket-адаптеры за протоколами (компиляция)',
    summary: 'WebSocketServing (start/send(to:)/broadcast/stop, onClient→хэндл+поток входящих RemoteMessage) + NWWebSocketServer (NWListener + NWProtocolWebSocket, текстовые фреймы, RemoteCodec). WebSocketClient (connect/send/disconnect, onMessage) + NWWebSocketClient (NWConnection + NWProtocolWebSocket, receive-loop, защита одного резюма по образцу MacSyncClient ContinuationBox). Рантайм-адаптеры: тестами не покрывать, swift test пакета остаётся зелёным. Замыкания @Sendable, переходы — Task{@MainActor}. Авторизация (hello/pair) НЕ в адаптере — в app (S5-4).' },
]

const IOS_TASKS = [
  { id: 'S5-4', phase: 'iOS', kind: 'app', target: 'ZverIOS', paths: ['Apps/ZverIOS'], verify: V_IOS,
    title: 'RemoteControlService: сервер, pairing-хост, команды, пуш, библиотека (компиляция)',
    summary: 'RemoteControlService (@MainActor): поднимает NWWebSocketServer, advertise _zver._tcp TXT {name,v:1,svc:remote}; pairing-хост (генерация/показ кода, Pairing.verify, выпуск токена в KeychainKeyStore(account:"zver-remote-token"), сервис zver-remote); авторизация соединения по hello{token} или pair{code}→paired{token} (до авторизации команды игнорируются); приём команд → PlayerEngine (play→resume/pause/togglePlayPause/next/previous/seek) и → LibraryStore (requestLibrary/requestAlbumTracks/playAlbum через RemoteLibraryBuilder: AlbumGroup→RemoteLibrary/albumTracks, резолв albumId+startIndex→[Track]→play). Наблюдение PlayerEngine.$state/$queue/$currentTime → RemoteStateDiff → broadcast(state). Замыкания сети @Sendable→Task{@MainActor}. НЕ трогать NowPlayingService. Файлы: Sources/Remote/RemoteControlService.swift, RemoteLibraryBuilder.swift, RemotePairingHost.swift + правка ZverIOSApp/ContentView.' },
  { id: 'S5-5', phase: 'iOS', kind: 'app', target: 'ZverIOS', paths: ['Apps/ZverIOS'], verify: V_IOS,
    title: 'Режимы паузы + silent keep-alive (компиляция)',
    summary: 'PauseMode {alwaysConnected, economical} (persist UserDefaults). KeepAlivePlayer: отдельный AVAudioPlayerNode + зацикленный буфер нулевых сэмплов на engine. PlayerEngine: поле pauseMode; в pause() при alwaysConnected — основной player.pause() (позиция сохраняется) + keep-alive тишина (iOS держит приложение живым, сессия активна, ЦАП захвачен, WS-сервер обслуживает команды); economical — текущее поведение; в resume()/loadAndPlay/seek/rebuildGraph — keep-alive стоп/переаттач. НЕ ломать gapless (prescheduleNext/sampleTimeBase), currentTime, MPRemoteCommandCenter, route/interruption. Чистую часть (решение «нужен ли keep-alive») по возможности вынести в маленький TDD-тест PauseMode; keep-alive — компиляция. Файлы: Sources/Audio/KeepAlivePlayer.swift, PauseMode.swift + правка PlayerEngine.swift.' },
  { id: 'S5-6', phase: 'iOS', kind: 'app', target: 'ZverIOS', paths: ['Apps/ZverIOS'], verify: V_IOS,
    title: 'Настройки и UI пульта на iPhone (компиляция)',
    summary: 'RemoteSettingsView: тумблер «Пульт с Мака», пикер режима паузы, кнопка «Показать код сопряжения» (6-значный код + окно ожидания), статус «Mac подключён»/«нет». Читает/пишет RemoteControlService. Добавить секцию «Пульт» в существующий экран Настроек этапа 4 (Cloud/SettingsView во вкладке «Облако»/«Настройки» — переименовать вкладку в «Настройки», секции «Облако» и «Пульт»), НЕ плодить вкладки. Проверить, что Local Network + UIBackgroundModes:[audio] ключи уже есть в project.yml (этап 3) — НЕ дублировать. Файлы: Sources/Remote/RemoteSettingsView.swift + правка ContentView/SettingsView.' },
]

const MAC_TASKS = [
  { id: 'S5-7', phase: 'Mac', kind: 'app', target: 'ZverMac', paths: ['Apps/ZverMac'], verify: V_MAC,
    title: 'RemoteClientCoordinator: browse, pairing-клиент, WS, приём состояния (компиляция)',
    summary: 'RemoteClientCoordinator (@MainActor, статус idle/discovering/discovered/pairing/connected/offline): browse _zver._tcp фильтром services(role:.remote) → выбор iPhone → если есть токен в Keychain (KeychainKeyStore(account:"zver-remote-token"), сервис=имя iPhone) → NWWebSocketClient connect → hello{token}; иначе ввод кода с iPhone → pair{code} → paired{token} сохранить → hello. После helloAck — приём library/state/albumTracks (RemoteClientStore агрегирует для UI), отправка команд. Деградация: соединение упало/iPhone пропал → offline («iPhone не в сети»), переподключение при возврате. Замыкания сети @Sendable→Task{@MainActor}. Зеркало ServerCoordinator/MacSyncClient (роли перевёрнуты). Файлы: Sources/Remote/RemoteClientCoordinator.swift, RemotePairingClient.swift, RemoteClientStore.swift.' },
  { id: 'S5-8', phase: 'Mac', kind: 'app', target: 'ZverMac', paths: ['Apps/ZverMac'], verify: V_MAC,
    title: 'Окно «Пульт»: транспорт, очередь, браузинг библиотеки (компиляция)',
    summary: 'RemoteControlView: текущий трек (title/artist/album/позиция) + транспорт (play-pause-next-prev) + слайдер seek + очередь + статус; биндинг к RemoteClientCoordinator (кнопки шлют команды, позицию между пушами интерполировать таймером при playback==playing). RemoteLibraryView: список RemoteAlbum → тап → requestAlbumTracks → список RemoteTrack → playAlbum(albumId,startIndex). Деградация «iPhone не в сети» + кнопка переподключения. Новое Window("Пульт", id:"remote") в ZverMacApp + пункт «Открыть пульт» в MenuBarExtra. Файлы: Sources/Remote/RemoteControlView.swift, RemoteLibraryView.swift + правка ZverMacApp.swift.' },
]

const FINAL_TASK = { id: 'S5-9', phase: 'Финал', kind: 'app', paths: ['README.md', 'docs/manual-test-checklist.md'], verify: V_FINAL,
  title: 'Финальный прогон и документация',
  summary: 'Прогнать swift test всех 4 пакетов (ZverCore/ZverMetadata/ZverTransport/ZverStorage) — зелёные; скомпилировать ОБА таргета (ZverIOS iOS + ZverMac macOS). README: блок «Этап 5 «Пульт»» (iPhone — WS-сервер, Mac — клиент/окно пульта, протокол, pairing с перевёрнутыми ролями, два режима паузы, браузинг библиотеки) + структура (+Remote/ в обоих приложениях и в ZverTransport). docs/manual-test-checklist.md: секция «Этап 5» (ручная проверка у владельца, iPhone+Mac в одной сети: включить пульт; Mac находит iPhone, сопряжение кодом; транспорт с Мака мгновенно; смена трека/позиции на iPhone отражается в пульте; браузинг библиотеки и запуск альбома; «всегда на связи» — команды доходят на паузе; «экономный» — пульт слепнет на паузе, оживает с локскрина; iPhone ушёл из сети → «iPhone не в сети» → возврат; MPRemoteCommandCenter/локскрин по-прежнему работают). Коммить ТОЛЬКО README.md и docs/manual-test-checklist.md (изменения app/пакетов тут не коммить — только верификация и доки).' }

// ─────────────────────────────── исполнение ───────────────────────────────

log('Этап 5 «Пульт»: цепочка ZverTransport (3 задачи) — протокол, Bonjour-роль, WebSocket-адаптеры')
const transportResults = await runChain(TRANSPORT_TASKS, 'ZverTransport')

log('Пакет готов. Параллельный старт цепочек iOS (3 задачи) и Mac (2 задачи) — разные таргеты.')
const [iosResults, macResults] = await parallel([
  () => runChain(IOS_TASKS, 'iOS'),
  () => runChain(MAC_TASKS, 'Mac'),
])

log('Интеграция готова. Финальный прогон и документация.')
const finalResult = await runTask(FINAL_TASK)

const all = [...transportResults, ...iosResults, ...macResults, finalResult]
const needsAttention = all.filter(r => r.status === 'needs-attention' || r.status === 'blocked' || r.status === 'skipped')
const backlog = all.flatMap(r => (r.minor || []).map(m => r.id + ': ' + (m.file ? m.file + ' — ' : '') + m.description))

log('ИТОГ: approved=' + all.filter(r => r.status === 'approved').length + '/' + all.length + ', needs-attention/blocked/skipped=' + needsAttention.length + ', backlog=' + backlog.length)

return {
  summary: all.map(r => r.id + ' [' + r.status + ']' + (r.reason ? ': ' + r.reason : '') + (r.round != null ? ' (фикс-кругов: ' + r.round + ')' : '')),
  approvedCount: all.filter(r => r.status === 'approved').length,
  total: all.length,
  needsAttention: needsAttention.map(r => ({ id: r.id, status: r.status, reason: r.reason, blocking: r.blocking || [] })),
  backlog,
  verifications: all.map(r => ({ id: r.id, verification: r.impl ? r.impl.verification : null, testsGreen: r.impl ? r.impl.testsGreen : null })),
}
