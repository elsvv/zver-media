# Single-file FLAC + .cue альбомы (image+cue) — дизайн и план реализации

Дата: 2026-07-02. Статус: согласовано, в реализации. Ветка: `feat/cue-single-file-albums`.

## Проблема

Аудиофильские рипы часто хранят весь CD как **один непрерывный `.flac`** + `.cue`-шит
с границами треков + `.log` (отчёт EAC/XLD). Пример из скрина: `Portishead - Dummy
(Japan, POCD-1153)` — `.cue` (1 КБ) + `.flac` (258 МБ) + `.log` (7 КБ). Сейчас
приложение проглатывает `.flac` как **один гигантский трек** на весь альбом; `.cue`
и `.log` вообще не переносятся (не в `audioExtensions`).

Цель: **первоклассная бесшовная** поддержка — обычный экран альбома с треклистом,
play/pause/scrub по треку, gapless — при этом **без потери побитовости**: оригинальный
`.flac` не режем и не перекодируем, играем диапазоны сэмплов; `.cue`+`.log` сохраняем.

## Инвариант, который ломаем

Весь стек держит «**1 трек = 1 физический файл**»:
`Track.id = url.path`; PK каталога = `relativePath`; офсетов нет; скан = 1 файл → 1
`AudioFileInfo`; плеер играет файл целиком. Cue-альбом = **N логических треков в одном
`.flac`** с диапазонами сэмплов.

## Границы v1 (согласовано)

- **Вход** — только Mac drag-drop (общий пайплайн синка Mac→iPhone). Импорта на устройстве нет.
- **Облако (Яндекс.Диск)** — **полный offload файла целиком**: контейнер `.flac` —
  единица облачного состояния, все N треков в лок-степе.
- **Метадата** — **read-only из `.cue`** (TITLE/PERFORMER по трекам) + правки на уровне
  альбома (название/обложка/год/описание) через существующий sidecar. Per-track
  редактирования на Маке в v1 нет.

---

## Ключевые решения

### Идентичность и хранение границ

Для cue-трека `url`/`relativePath` **остаётся путём физического `.flac`** (контейнера),
чтобы плеер/reconcile/загрузка работали по реальному файлу. Различие даёт новый
**`trackKey`** (стабильная идентичность):

- обычный трек: `trackKey = relativePath`;
- cue-трек: `trackKey = "\(relativePath)#\(cueIndex)"`, где `cueIndex` = 1-based номер
  трека в cue.

Границы храним **в сэмплах** (sample-accurate = побитово), не в секундах:
`startFrame: Int64`, `frameCount: Int64`. `isCueTrack == (startFrame != nil)`.

### Границы = INDEX 01 (пре-гэп остаётся у предыдущего трека)

`startFrame[i] = round((MM·60 + SS + FF/75) · sampleRate)` по времени `INDEX 01` трека
(из `FormatProbe.sampleRate`). `frameCount[i] = startFrame[i+1] − startFrame[i]`.
**Режем по `INDEX 01`** (де-факто стандарт EAC/foobar2000): пре-гэп `[INDEX 00, INDEX 01)`
остаётся в конце ПРЕДЫДУЩЕГО трека, начало трека = его `INDEX 01`. У последнего трека
`frameCount = nil` («до конца файла») — плеер доигрывает до реальной `AVAudioFile.length`,
не до оценочной длительности (иначе недооценка обрезала бы побитовый хвост); `duration`
для показа — оценка.

### Правило раскрытия

Раскрываем в N треков **только если `.cue` ссылается ровно на ОДИН `FILE`** (image+cue).
Если `FILE` на каждый трек — обычный многофайловый альбом, `.cue` игнорим. Multi-disc
(несколько `.flac`+`.cue` по папкам) композится с текущей логикой дисков: каждый image →
свои треки, `discLabel` из папки.

### Транспорт: офсеты живут ТОЛЬКО в `.cue`

Каталог на устройстве всегда строится `LibraryScanner`-ом по Documents (не из манифеста).
Значит device всё равно перепарсивает `.cue`. Поэтому **офсеты в манифест НЕ кладём**
(нет дрейфа между manifest-офсетами и cue-офсетами):
- `manifest.tracks[]` — N превью-треков, делящих один `fileName` (= `.flac`), несут только
  title/artist/index для превью импорта;
- новый канал `manifest.album.extras: [ManifestFile]` несёт `.cue` (авторитетные офсеты) и
  `.log` (целостность релиза);
- device качает `.flac` один раз (дедуп по `fileName`) + extras, затем `rescan()` →
  `LibraryScanner` раскрывает `.cue` → авторитетные N треков каталога.

### Облако: контейнер — единица состояния (лок-степ)

Схему `fileState`/`cloudSha` (per-row) **не меняем**; вместо этого держим все N cue-строк
одного контейнера **в лок-степе**: любая облачная операция (backup/offload/download)
дедупится и ключуется по `relativePath` (контейнеру), физический upload/download/delete
файла — **один раз**, апдейт `fileState`/`cloudSha` — по всем N строкам в одной
транзакции. UI-бейдж читает любую строку (они синхронны). Тап по `remote` cue-треку →
скачать контейнер → доступны все N.

---

## Изменения по слоям

### 1. `ZverMetadata` — парсер + скан (пакет, headless-тесты)

**`CueSheet.swift`** (новый, брат `M3UPlaylist.swift`; чистый строковый, без IO):
- `parse(from content: String) -> CueSheet` — разбирает `FILE "x.flac" WAVE`,
  `TRACK NN AUDIO`, `TITLE`, `PERFORMER`, `INDEX 00/01 MM:SS:FF`, `REM DATE/GENRE`.
- Модель: `struct CueSheet { let files: [CueFile] }`, `CueFile { fileName; tracks:[CueTrack] }`,
  `CueTrack { index:Int; title:String?; performer:String?; startFrames75:Int /* INDEX01 в 1/75с */ }`.
- `isSingleFileImage: Bool` (== `files.count == 1 && files[0].tracks.count > 1`).
- Хелпер `frameOffsets(sampleRate:) -> [Int64]` — конвертит `startFrames75` в сэмплы.

**Кодировки** — расширить общий `readText`: UTF-8 → **Shift-JIS** (яп. рипы) → system →
Latin-1. (Сейчас в `LibraryScanner.readText`.)

**`AudioFileInfo`** (`MetadataReader.swift`) — добавить `cueIndex: Int?`,
`startFrame: Int64?`, `frameCount: Int64?` (nil у обычных; `url` = контейнер).

**`LibraryScanner.scan`** — детект «один аудиофайл + рядом одноимённый `.cue`»:
если `.cue` рядом и `isSingleFileImage` → `MetadataReader` читает формат контейнера
(sampleRate/duration), затем эмитим **N `AudioFileInfo`** из одного `.flac` с
`cueIndex/startFrame/frameCount`, title/artist из cue (fallback — теги/имя). Иначе —
прежнее поведение. `.cue` добавить в распознаваемые (рядом с `playlistExtensions`), чтобы
`albumRoot`/`FolderFacts` знали про него. Работает на Маке (draft) и на телефоне (каталог).

**Тесты:** парс cue (single/multi-FILE, INDEX00/01, MM:SS:FF, REM); Shift-JIS; frames→samples;
скан «flac+cue» → N `AudioFileInfo` с корректными офсетами; multi-FILE cue не раскрывается;
обычные альбомы не меняются.

### 2. `ZverCore` — модель + каталог (пакет, headless-тесты)

**`Track.swift`** — добавить `cueIndex: Int?`, `startFrame: Int64?`, `frameCount: Int64?`;
`id` = `trackKey` (обычный: `url.path`; cue: `"\(url.path)#\(cueIndex!)"`);
computed `isCueTrack`. `url` = контейнер.

**`TrackRecord.swift`** — добавить колонки `cueIndex`, `startFrame`, `frameCount`; новая
PK-колонка `trackKey` (text). `track(documentsURL:)` строит `Track` с офсетами; `init(track:…)`
пишет `trackKey`.

**`Catalog.swift` — миграция v5:** пересоздать `track` с PK `trackKey` (SQLite не умеет
ALTER PK): создать `track_new` (новая схема) → скопировать старые строки
(`trackKey = relativePath`, новые колонки NULL) → пересоздать `playlistTrack` с FK на
`trackKey` (маппинг `trackRelativePath → trackKey`, для существующих = `relativePath`) →
drop/rename. Плейлисты (пользовательские данные) **сохранить**. Аддитивно к v2–v4.

**`CatalogStore.swift`** — `reconcile` и upsert/delete ключевать по **`trackKey`** (чтобы N
cue-строк с общим `relativePath` сосуществовали); проверка наличия на диске и файловые
операции — по `relativePath` (контейнер); если `.flac` пропал → удаляются все N строк.
Облачные апдейтеры (`setFileState`/`markBackedUp`/…) — вариант «по всем строкам данного
`relativePath`» (лок-степ), см. слой 5.

**Тесты:** миграция v5 (round-trip, сохранность плейлистов, `trackKey`); reconcile с N
cue-строками одного контейнера (upsert/удаление при пропаже файла); обычные треки не задеты.

### 3. `PlayerEngine` (iOS) — воспроизведение диапазонов + gapless

Плеер уже умеет `scheduleSegment(startingFrame:frameCount:)`. Обобщить учёт кадров, зашитый
сейчас на «сегмент до конца файла, каждый трек = файл с кадра 0»:
- Ввести состояние текущего сегмента: `segStartFrame`, `segFrameCount` (вместо вывода из
  `file.length`). Клампить `segFrameCount = min(stored, file.length - segStartFrame)`.
- `loadAndPlay`: для cue-трека — `scheduleSegment(startingFrame: track.startFrame,
  frameCount: track.frameCount)`; `startFrame = track.startFrame`.
- `reschedule` (seek): клампить target/остаток в `[segStartFrame, segStartFrame+segFrameCount]`,
  не в `[0, file.length]`.
- `prescheduleNext`: **same-file ветка** — если следующий трек тот же `url` (cue-сосед),
  переиспользовать открытый `file` и `scheduleSegment` его диапазона (тот же формат →
  gapless бесплатно, ЦАП лочится один раз).
- `handleTrackFinished`: `sampleTimeBase += фактически сыгранная длина сегмента` (не
  `finished.length - startFrame`); входящему треку `startFrame = его segStartFrame`,
  `currentTime = его старт в сек`; при same-file — **не** переоткрывать `file`.
- `previous()`: «рестарт текущего» = seek к старту трека (не к 0); порог `> 3с` — от старта трека.
- `updateCurrentTime`/UI/`NowPlayingService`/`changePlaybackPositionCommand`: конверсия
  абсолютной позиции файла ↔ позиции внутри трека (`displayed = currentTime − trackStartSec`;
  `seekTarget = uiSec + trackStartSec`; `duration`/`elapsed` — по треку).

**Проверка:** только `xcodebuild build` (compile-gate) + ручная на устройстве (см. чеклист).

### 4. Транспорт + импорт (`ZverTransport` + Mac + iOS)

- **`ManifestAlbum.swift`** — добавить `extras: [ManifestFile]` (как `artwork`/`playlist`:
  имя+sha+size). N `ManifestTrack` для cue-альбома делят один `fileName`.
- **Mac `AlbumDraft`/`ManifestBuilder`** — draft уже получит N треков (скан раскрывает cue);
  собрать `extras` из `.cue`/`.log` в корне альбома; **хешировать каждый уникальный `fileName`
  ровно один раз** (дедуп — не хешировать 258 МБ N раз; учли урок CPU-kill).
- **`SyncHost.refreshSnapshot`** — добавить `extras` в servable-карту (`albumId/fileName`).
- **`SyncPlanner.plan`** — **дедуп планируемых аудиофайлов по `fileName`** (качать `.flac`
  один раз) + план `extras`; новый `PlannedFile.Kind` (`.extra`).
- **iOS `ImportCoordinator`/`DownloadEngine`** — `fileCount`/`computeLocalShas`/
  `pruneStaleFiles` keep-set: добавить extras (`.cue`/`.log`), чтобы их не удаляло и
  считало; воссоздание дерева — как для треков.

**Тесты (ZverTransport):** round-trip `extras` в манифесте (обратная совместимость —
старые манифесты без `extras`); planner дедупит аудио по `fileName` и планирует extras;
keep-set не трогает `.cue`/`.log`.

### 5. Облако — контейнер как единица (iOS + `ZverCore`/`ZverStorage`)

- `CatalogStore` — облачные апдейтеры оперируют **всеми строками данного `relativePath`**
  (лок-степ): `setFileState(container:…)`, `markBackedUp(container:sha:)`, etc.
- `BackupQueue` — дедуп по `relativePath` (контейнер грузится один раз); по успеху — пометить
  backedUp все N строк.
- Offload/download UI — оперируют контейнером: «Выгрузить» удаляет `.flac` при совпадении sha,
  все N треков → `remote`; тап по `remote`-cue-треку → скачать контейнер.

**Проверка:** `swift test ZverCore` (лок-степ апдейтеры) + `xcodebuild build` + ручная.

---

## План работ (стадии для воркфлоу)

Пакеты (`swift test`) — надёжный гейт; приложения — `xcodebuild build` compile-gate +
ручная на устройстве (владелец).

1. **Параллельно (независимые пакеты):**
   - S1-META: `ZverMetadata` — CueSheet + AudioFileInfo-поля + LibraryScanner-раскрытие + Shift-JIS + тесты → `swift test` green.
   - S1-CORE: `ZverCore` — Track/TrackRecord/миграция v5/trackKey/CatalogStore-by-trackKey + тесты → `swift test` green.
2. **Последовательно (после ядра):**
   - S2-TRANSPORT: `ZverTransport` extras + Mac draft/builder/host + iOS planner/coordinator/prune + тесты ZverTransport → green; `xcodebuild build` best-effort.
   - S2-PLAYBACK: `PlayerEngine` диапазоны + same-file gapless + офсет-конверсия UI/локскрин; `xcodebuild build`.
   - S2-CLOUD: контейнер-лок-степ (CatalogStore/BackupQueue/UI); `swift test ZverCore` + `xcodebuild build`.
3. **Ревью (параллельно, адверсариально):** матем. кадров в плеере; безопасность миграции v5
   (сохранность плейлистов); полнота wire-контракта (extras сквозь все слои); когерентность
   облачного лок-степа; корректность gapless/пре-гэп.

Не коммитить и не мержить — оставить изменения в ветке `feat/cue-single-file-albums` для
ревью и ручной проверки на устройстве.

## Тест-фикстуры

Добавить в `Packages/ZverMetadata/Tests/.../Fixtures`: маленький single-file `.flac` +
`.cue` (2–3 трека, INDEX01), multi-FILE `.cue` (не должен раскрываться), Shift-JIS `.cue`.
