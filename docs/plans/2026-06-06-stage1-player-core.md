# Zver Cloud — Этап 1 «Ядро плеера»: Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (или superpowers:subagent-driven-development в той же сессии) to implement this plan task-by-task.

**Goal:** iOS-приложение, которое играет FLAC/ALAC из Documents (импорт через Files app), переключает sample rate USB ЦАПа под трек, управляется с локскрина и имеет мини-плеер + полноэкранный плеер.

**Architecture:** Монорепо: два SPM-пакета с чистой логикой (`ZverCore` — модели/очередь/координатор частоты, `ZverMetadata` — парсинг тегов и сканер папки), тестируемые `swift test` на macOS; iOS-приложение `ZverIOS` (XcodeGen) содержит только платформенный код: AVAudioEngine-движок, AVAudioSession-адаптер, MPNowPlaying, SwiftUI.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation/AudioToolbox, MediaPlayer, XcodeGen. Без внешних зависимостей.

**Контекст:** дизайн — `docs/plans/2026-06-06-zver-cloud-design.md`. Ключевые факты из ресёрча уже там (FLAC через AVAudioFile нативно; Vorbis-теги через `metadata(forFormat: "org.xiph.vorbis-comment")`, `commonMetadata` для FLAC ПУСТОЙ; artwork = сырые байты в item `METADATA_BLOCK_PICTURE`; sample rate: `setPreferredSampleRate` + обязательный readback).

**Правила для исполнителя:**
- TDD: тест → убедиться что падает → минимальная реализация → тест зелёный → коммит.
- Тесты пакетов гонять из папки пакета: `cd Packages/<имя> && swift test`.
- Билд приложения: `xcodebuild -project Apps/ZverIOS/ZverIOS.xcodeproj -scheme ZverIOS -destination "platform=iOS Simulator,name=$SIM" build` где `SIM` — первый доступный iPhone из `xcrun simctl list devices available`.
- Коммиты частые, сообщения `feat:/test:/chore:` на русском.
- AVAudioSession есть ТОЛЬКО на iOS — в пакеты не тащить, только протокол-абстракция.

---

## Task 1: Каркас репозитория и тулчейн

**Files:**
- Create: `.gitignore`, `README.md`, `Packages/`, `Apps/`, `scripts/`

**Step 1: Проверить тулчейн**

```bash
xcodebuild -version            # ожидаем Xcode 16+
which xcodegen || brew install xcodegen
which ffmpeg || brew install ffmpeg
which metaflac || brew install flac
xcrun simctl list devices available | grep -m1 iPhone
```

**Step 2: .gitignore**

```
.DS_Store
xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
.build/
DerivedData/
*.ipa
```
(`ZverIOS.xcodeproj` генерируется XcodeGen — добавить `Apps/ZverIOS/ZverIOS.xcodeproj` в .gitignore, источник правды — `project.yml`.)

**Step 3: README.md** — кратко: что это, структура папок, как собрать (xcodegen + xcodebuild), как тестировать пакеты.

**Step 4: Commit** — `chore: каркас репозитория`

---

## Task 2: ZverCore — Track и PlaybackQueue (TDD)

**Files:**
- Create: `Packages/ZverCore/Package.swift`
- Create: `Packages/ZverCore/Sources/ZverCore/Track.swift`
- Create: `Packages/ZverCore/Sources/ZverCore/PlaybackQueue.swift`
- Test: `Packages/ZverCore/Tests/ZverCoreTests/PlaybackQueueTests.swift`

**Step 1: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZverCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZverCore", targets: ["ZverCore"])],
    targets: [
        .target(name: "ZverCore"),
        .testTarget(name: "ZverCoreTests", dependencies: ["ZverCore"]),
    ]
)
```

**Step 2: Track.swift (модель — без TDD, это данные)**

```swift
import Foundation

public struct Track: Identifiable, Equatable, Hashable, Sendable {
    public let id: String          // стабильный: путь файла
    public var url: URL
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var duration: Double    // секунды
    public var sampleRate: Double  // Гц
    public var bitDepth: Int?
    public var fileExtension: String

    public init(url: URL, title: String, artist: String? = nil, album: String? = nil,
                trackNumber: Int? = nil, year: Int? = nil, duration: Double,
                sampleRate: Double, bitDepth: Int? = nil) {
        self.id = url.path
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.year = year
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.fileExtension = url.pathExtension.lowercased()
    }
}
```

**Step 3: Падающие тесты очереди**

```swift
import Testing
@testable import ZverCore

private func makeTrack(_ n: Int) -> Track {
    Track(url: URL(fileURLWithPath: "/t/\(n).flac"), title: "T\(n)",
          duration: 60, sampleRate: 44100)
}

@Suite struct PlaybackQueueTests {
    @Test func startSetsCurrent() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1), makeTrack(2)], at: 0)
        #expect(q.current?.title == "T1")
    }
    @Test func advanceMovesForwardAndStopsAtEnd() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1), makeTrack(2)], at: 0)
        #expect(q.advance()?.title == "T2")
        #expect(q.advance() == nil)          // конец очереди
        #expect(q.current == nil)
    }
    @Test func goBackMovesBackAndClampsAtStart() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1), makeTrack(2)], at: 1)
        #expect(q.goBack()?.title == "T1")
        #expect(q.goBack()?.title == "T1")   // не уходит ниже 0
    }
    @Test func startAtIndexOutOfBoundsClamps() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1)], at: 5)
        #expect(q.current?.title == "T1")
    }
}
```

**Step 4:** `cd Packages/ZverCore && swift test` → FAIL (PlaybackQueue не существует)

**Step 5: Минимальная реализация PlaybackQueue.swift**

```swift
public struct PlaybackQueue: Equatable, Sendable {
    public private(set) var tracks: [Track] = []
    public private(set) var currentIndex: Int? = nil

    public init() {}

    public var current: Track? { currentIndex.map { tracks[$0] } }

    public mutating func start(tracks: [Track], at index: Int) {
        self.tracks = tracks
        self.currentIndex = tracks.isEmpty ? nil : min(max(index, 0), tracks.count - 1)
    }

    @discardableResult
    public mutating func advance() -> Track? {
        guard let i = currentIndex else { return nil }
        guard i + 1 < tracks.count else { currentIndex = nil; return nil }
        currentIndex = i + 1
        return current
    }

    @discardableResult
    public mutating func goBack() -> Track? {
        guard let i = currentIndex else { return nil }
        currentIndex = max(i - 1, 0)
        return current
    }
}
```

**Step 6:** `swift test` → PASS

**Step 7: Commit** — `feat: ZverCore — Track и PlaybackQueue`

---

## Task 3: ZverCore — SampleRateCoordinator (TDD)

Логика переключения частоты ЦАПа, отделённая от AVAudioSession протоколом (тестируется моком; реальный адаптер — в приложении, Task 9).

**Files:**
- Create: `Packages/ZverCore/Sources/ZverCore/SampleRateCoordinator.swift`
- Test: `Packages/ZverCore/Tests/ZverCoreTests/SampleRateCoordinatorTests.swift`

**Step 1: Падающие тесты**

```swift
import Testing
@testable import ZverCore

final class MockSession: AudioSessionControlling {
    var currentSampleRate: Double
    var supported: Set<Double>          // что «умеет» ЦАП
    var setCalls: [Double] = []
    var readbackLies = false            // имитация бага iOS 18.0

    init(rate: Double, supported: Set<Double>) {
        self.currentSampleRate = rate
        self.supported = supported
    }
    func setPreferredSampleRate(_ rate: Double) throws {
        setCalls.append(rate)
        if supported.contains(rate) && !readbackLies { currentSampleRate = rate }
    }
}

@Suite struct SampleRateCoordinatorTests {
    @Test func switchesToFileRateWhenSupported() {
        let s = MockSession(rate: 44100, supported: [44100, 48000, 96000, 192000])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 96000)
        #expect(plan.effective == 96000)
        #expect(plan.switched)
    }
    @Test func fallsBackToReadbackWhenUnsupported() {
        let s = MockSession(rate: 48000, supported: [44100, 48000])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 192000)
        #expect(plan.effective == 48000)   // граф соберём на фактической
        #expect(!plan.switched)
    }
    @Test func noSetCallWhenAlreadyAtFileRate() {
        let s = MockSession(rate: 96000, supported: [96000])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 96000)
        #expect(s.setCalls.isEmpty)        // не дёргаем сессию зря
        #expect(plan.effective == 96000)
    }
    @Test func toleratesTinyRateDifference() {
        let s = MockSession(rate: 44099.9999, supported: [])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 44100)
        #expect(plan.switched)             // |Δ| < 1 Гц — считаем совпадением
    }
}
```

**Step 2:** `swift test` → FAIL

**Step 3: Реализация**

```swift
public protocol AudioSessionControlling {
    var currentSampleRate: Double { get }
    func setPreferredSampleRate(_ rate: Double) throws
}

public struct SampleRatePlan: Equatable, Sendable {
    public let requested: Double
    public let effective: Double   // на этой частоте собирать аудиограф
    public let switched: Bool
}

public enum SampleRateCoordinator {
    /// Переключает сессию на частоту файла. Всегда доверяем readback:
    /// если ЦАП не умеет частоту (или iOS наврала) — граф собираем на
    /// фактической частоте, ресемплинг сделает системный микшер.
    public static func prepare(session: AudioSessionControlling,
                               fileRate: Double) -> SampleRatePlan {
        if abs(session.currentSampleRate - fileRate) < 1.0 {
            return SampleRatePlan(requested: fileRate, effective: fileRate, switched: true)
        }
        try? session.setPreferredSampleRate(fileRate)
        let readback = session.currentSampleRate
        let ok = abs(readback - fileRate) < 1.0
        return SampleRatePlan(requested: fileRate,
                              effective: ok ? fileRate : readback,
                              switched: ok)
    }
}
```

**Step 4:** `swift test` → PASS
**Step 5: Commit** — `feat: SampleRateCoordinator — переключение частоты ЦАПа за протоколом`

---

## Task 4: Аудио-фикстуры для тестов метаданных

**Files:**
- Create: `scripts/make-fixtures.sh`
- Create (генерируются): `Packages/ZverMetadata/Tests/ZverMetadataTests/Fixtures/{tagged_16_44.flac, hires_24_96.flac, notags.flac, alac.m4a}`

**Step 1: Скрипт**

```bash
#!/bin/bash
# Генерирует эталонные аудиофайлы для тестов ZverMetadata.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/Packages/ZverMetadata/Tests/ZverMetadataTests/Fixtures"
mkdir -p "$DIR"; cd "$DIR"

# 1 секунда синуса 440 Гц
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 44100 -sample_fmt s16 tagged_16_44.flac
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 96000 -af aformat=sample_fmts=s32 \
       -bits_per_raw_sample 24 hires_24_96.flac
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 44100 -sample_fmt s16 notags.flac
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 44100 -c:a alac alac.m4a

# Vorbis-теги
metaflac --set-tag="TITLE=Тестовый трек" --set-tag="ARTIST=Зверь" \
         --set-tag="ALBUM=Фикстуры" --set-tag="TRACKNUMBER=3" \
         --set-tag="DATE=2024" tagged_16_44.flac
metaflac --set-tag="TITLE=Hi-Res" --set-tag="ARTIST=Зверь" \
         --set-tag="ALBUM=Фикстуры" hires_24_96.flac

# Обложка: 1x1 красный PNG из base64 (без зависимостей от ImageMagick)
echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" \
  | base64 -d > cover.png
metaflac --import-picture-from=cover.png tagged_16_44.flac
rm cover.png

# Контроль
metaflac --list --block-type=STREAMINFO hires_24_96.flac | grep -E "sample_rate|bits-per-sample"
afinfo alac.m4a | head -5
```

**Step 2: Запустить, проверить вывод**

Run: `chmod +x scripts/make-fixtures.sh && ./scripts/make-fixtures.sh`
Expected: STREAMINFO показывает `sample_rate: 96000`, `bits-per-sample: 24`; afinfo показывает `alac`.

**Step 3: Commit** — `test: аудиофикстуры (FLAC 16/44.1 с тегами и обложкой, 24/96, без тегов, ALAC)` — фикстуры маленькие (<200 КБ суммарно), коммитим бинарники.

---

## Task 5: ZverMetadata — проба формата (TDD)

**Files:**
- Create: `Packages/ZverMetadata/Package.swift` (по образцу ZverCore + `resources: [.copy("Fixtures")]` у тест-таргета)
- Create: `Packages/ZverMetadata/Sources/ZverMetadata/AudioFileInfo.swift`
- Create: `Packages/ZverMetadata/Sources/ZverMetadata/FormatProbe.swift`
- Test: `Packages/ZverMetadata/Tests/ZverMetadataTests/FormatProbeTests.swift`

**Step 1: Падающие тесты**

```swift
import Testing
import Foundation
@testable import ZverMetadata

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
}

@Suite struct FormatProbeTests {
    @Test func probesHiResFlac() throws {
        let info = try FormatProbe.probe(url: fixture("hires_24_96.flac"))
        #expect(info.sampleRate == 96000)
        #expect(info.bitDepth == 24)
        #expect(abs(info.duration - 1.0) < 0.1)
    }
    @Test func probesCdQualityFlac() throws {
        let info = try FormatProbe.probe(url: fixture("tagged_16_44.flac"))
        #expect(info.sampleRate == 44100)
        #expect(info.bitDepth == 16)
    }
    @Test func probesAlac() throws {
        let info = try FormatProbe.probe(url: fixture("alac.m4a"))
        #expect(info.sampleRate == 44100)
    }
    @Test func throwsOnGarbage() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("x.flac")
        try? Data("не аудио".utf8).write(to: tmp)
        #expect(throws: (any Error).self) { try FormatProbe.probe(url: tmp) }
    }
}
```

**Step 2:** `cd Packages/ZverMetadata && swift test` → FAIL

**Step 3: Реализация через AudioToolbox** (надёжнее AVAudioFile для bit depth — есть `kAudioFilePropertySourceBitDepth`)

```swift
import AudioToolbox
import Foundation

public struct ProbedFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let bitDepth: Int?
    public let duration: Double
}

public enum FormatProbeError: Error { case cannotOpen(OSStatus) }

public enum FormatProbe {
    public static func probe(url: URL) throws -> ProbedFormat {
        var fileID: AudioFileID?
        let st = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard st == noErr, let file = fileID else { throw FormatProbeError.cannotOpen(st) }
        defer { AudioFileClose(file) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)

        var bitDepth: Int32 = 0
        size = UInt32(MemoryLayout.size(ofValue: bitDepth))
        let bdStatus = AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &bitDepth)

        var duration: Double = 0
        size = UInt32(MemoryLayout.size(ofValue: duration))
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)

        return ProbedFormat(sampleRate: asbd.mSampleRate,
                            bitDepth: bdStatus == noErr && bitDepth > 0 ? Int(bitDepth) : nil,
                            duration: duration)
    }
}
```

**Step 4:** `swift test` → PASS (если bitDepth для ALAC nil — это допустимо, тест на ALAC bit depth не пишем)
**Step 5: Commit** — `feat: FormatProbe — sampleRate/bitDepth/duration через AudioToolbox`

---

## Task 6: ZverMetadata — Vorbis-теги и artwork (TDD)

**Files:**
- Create: `Packages/ZverMetadata/Sources/ZverMetadata/MetadataReader.swift`
- Test: `Packages/ZverMetadata/Tests/ZverMetadataTests/MetadataReaderTests.swift`

**Step 1: Падающие тесты**

```swift
@Suite struct MetadataReaderTests {
    @Test func readsVorbisTagsFromFlac() async throws {
        let info = try await MetadataReader.read(url: fixture("tagged_16_44.flac"))
        #expect(info.title == "Тестовый трек")
        #expect(info.artist == "Зверь")
        #expect(info.album == "Фикстуры")
        #expect(info.trackNumber == 3)
        #expect(info.year == 2024)
    }
    @Test func extractsArtworkBytes() async throws {
        let info = try await MetadataReader.read(url: fixture("tagged_16_44.flac"))
        let art = try #require(info.artworkData)
        #expect(art.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) // PNG magic
    }
    @Test func untaggedFileFallsBackToFilename() async throws {
        let info = try await MetadataReader.read(url: fixture("notags.flac"))
        #expect(info.title == "notags")     // имя файла без расширения
        #expect(info.artist == nil)
    }
    @Test func readsAlacCommonMetadata() async throws {
        let info = try await MetadataReader.read(url: fixture("alac.m4a"))
        #expect(info.sampleRate == 44100)   // формат есть всегда, теги — опционально
    }
}
```

**Step 2:** `swift test` → FAIL

**Step 3: Реализация.** Ключевое из ресёрча: для FLAC `commonMetadata` пуст; правильный путь — формат `org.xiph.vorbis-comment`; artwork — item с ключом `METADATA_BLOCK_PICTURE`, `dataValue` = сырые байты картинки.

```swift
import AVFoundation
import Foundation

public struct AudioFileInfo: Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int?
    public var artworkData: Data?
    public var url: URL
}

public enum MetadataReader {
    public static func read(url: URL) async throws -> AudioFileInfo {
        let probed = try FormatProbe.probe(url: url)
        let asset = AVURLAsset(url: url)

        var tags: [String: String] = [:]
        var artwork: Data?

        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            let items = (try? await asset.loadMetadata(for: format)) ?? []
            for item in items {
                let key = (item.key as? String) ?? item.commonKey?.rawValue ?? ""
                switch key.uppercased() {
                case "METADATA_BLOCK_PICTURE":
                    artwork = try? await item.load(.dataValue)
                default:
                    if let v = try? await item.load(.stringValue) {
                        tags[key.uppercased()] = v
                    }
                }
            }
            // common-ключи (ALAC/iTunes-атомы)
            for item in items where item.commonKey != nil {
                if item.commonKey == .commonKeyArtwork, artwork == nil {
                    artwork = try? await item.load(.dataValue)
                }
            }
        }

        // commonMetadata fallback (ALAC)
        if tags["TITLE"] == nil {
            let common = (try? await asset.load(.commonMetadata)) ?? []
            for item in common {
                guard let ck = item.commonKey else { continue }
                let v = try? await item.load(.stringValue)
                switch ck {
                case .commonKeyTitle:      tags["TITLE"] = v
                case .commonKeyArtist:     tags["ARTIST"] = v
                case .commonKeyAlbumName:  tags["ALBUM"] = v
                default: break
                }
            }
        }

        return AudioFileInfo(
            title: tags["TITLE"] ?? url.deletingPathExtension().lastPathComponent,
            artist: tags["ARTIST"],
            album: tags["ALBUM"],
            trackNumber: tags["TRACKNUMBER"].flatMap { Int($0.prefix(while: \.isNumber)) },
            year: tags["DATE"].flatMap { Int($0.prefix(4)) },
            duration: probed.duration,
            sampleRate: probed.sampleRate,
            bitDepth: probed.bitDepth,
            artworkData: artwork,
            url: url
        )
    }
}
```

**Step 4:** `swift test` → PASS. ВАЖНО: если тест artwork падает (поведение `METADATA_BLOCK_PICTURE` различается между версиями ОС — иногда dataValue это base64 FLAC-Picture-блок, а не сырая картинка), добавить декодирование: если первые байты не PNG/JPEG magic — попробовать base64-decode → распарсить FLAC METADATA_BLOCK_PICTURE структуру (32-бит big-endian поля: type, mime len, mime, desc len, desc, w, h, depth, colors, data len, data). Зафиксировать фактическое поведение комментарием.
**Step 5: Commit** — `feat: MetadataReader — Vorbis-теги и artwork из FLAC, common из ALAC`

---

## Task 7: ZverMetadata — LibraryScanner (TDD)

**Files:**
- Create: `Packages/ZverMetadata/Sources/ZverMetadata/LibraryScanner.swift`
- Test: `Packages/ZverMetadata/Tests/ZverMetadataTests/LibraryScannerTests.swift`

**Step 1: Падающие тесты** — во временной папке раскладываем копии фикстур (вложенные подпапки, чужие файлы `.txt`, `.jpg`), сканер: находит только аудио (`flac/m4a/mp3/wav/aiff/opus`), рекурсивно, сортировка по пути, для каждого — `AudioFileInfo`.

```swift
@Suite struct LibraryScannerTests {
    @Test func findsAudioRecursivelyIgnoringJunk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом A")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try fm.copyItem(at: fixture("alac.m4a"), to: tmp.appendingPathComponent("solo.m4a"))
        try Data("мусор".utf8).write(to: sub.appendingPathComponent("readme.txt"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 2)
        #expect(infos.allSatisfy { ["flac", "m4a"].contains($0.url.pathExtension) })
    }
    @Test func emptyDirGivesEmptyResult() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        #expect(try await LibraryScanner.scan(directory: tmp).isEmpty)
    }
}
```

**Step 2:** FAIL → **Step 3: Реализация** — `FileManager.enumerator`, фильтр по расширениям `["flac","m4a","mp3","wav","aiff","aif","opus"]`, для каждого файла `MetadataReader.read`, битые файлы пропускать (не валить весь скан), результат сортировать по `url.path`.

**Step 4:** PASS → **Step 5: Commit** — `feat: LibraryScanner — рекурсивный скан папки с метаданными`

---

## Task 8: Приложение ZverIOS — каркас XcodeGen

**Files:**
- Create: `Apps/ZverIOS/project.yml`
- Create: `Apps/ZverIOS/Sources/ZverIOSApp.swift`, `Apps/ZverIOS/Sources/ContentView.swift` (заглушка)

**Step 1: project.yml**

```yaml
name: ZverIOS
options:
  bundleIdPrefix: dev.zver
  deploymentTarget:
    iOS: "17.0"
packages:
  ZverCore:
    path: ../../Packages/ZverCore
  ZverMetadata:
    path: ../../Packages/ZverMetadata
targets:
  ZverIOS:
    type: application
    platform: iOS
    sources: [Sources]
    dependencies:
      - package: ZverCore
      - package: ZverMetadata
    settings:
      base:
        SWIFT_VERSION: "6.0"
        CODE_SIGN_STYLE: Automatic
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        TARGETED_DEVICE_FAMILY: "1"
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: Zver
        UILaunchScreen: {}
        UIBackgroundModes: [audio]
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
```

**Step 2: Заглушка приложения**

```swift
import SwiftUI

@main
struct ZverIOSApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
```
`ContentView` — `Text("Zver")`.

**Step 3: Сгенерировать и собрать**

```bash
cd Apps/ZverIOS && xcodegen generate
SIM=$(xcrun simctl list devices available | grep -m1 -o 'iPhone [^(]*' | xargs)
xcodebuild -project ZverIOS.xcodeproj -scheme ZverIOS \
  -destination "platform=iOS Simulator,name=$SIM" build
```
Expected: `BUILD SUCCEEDED`

**Step 4: Commit** — `feat: каркас iOS-приложения (XcodeGen, background audio, File Sharing)`

---

## Task 9: PlayerEngine — воспроизведение через AVAudioEngine

Платформенный код — юнит-тесты не пишем (AVAudioSession/Engine не мокаются разумно); проверка — билд + ручной прогон. Логика очереди и частот уже покрыта тестами в ZverCore.

**Files:**
- Create: `Apps/ZverIOS/Sources/Audio/SystemAudioSession.swift`
- Create: `Apps/ZverIOS/Sources/Audio/PlayerEngine.swift`

**Step 1: Адаптер сессии**

```swift
import AVFAudio
import ZverCore

/// Реальный AVAudioSession за протоколом из ZverCore.
struct SystemAudioSession: AudioSessionControlling {
    var currentSampleRate: Double { AVAudioSession.sharedInstance().sampleRate }
    func setPreferredSampleRate(_ rate: Double) throws {
        try AVAudioSession.sharedInstance().setPreferredSampleRate(rate)
    }
}
```

**Step 2: PlayerEngine** — ключевые требования:

```swift
import AVFAudio
import Combine
import ZverCore

@MainActor
final class PlayerEngine: ObservableObject {
    enum State: Equatable { case idle, playing, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var currentTime: Double = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0   // для seek/currentTime
    private var timeObserver: Timer?
    private let session: AudioSessionControlling

    init(session: AudioSessionControlling = SystemAudioSession()) {
        self.session = session
        engine.attach(player)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    func play(tracks: [Track], startAt index: Int) { /* queue.start + loadAndPlay(current) */ }
    func togglePlayPause() { /* player.pause()/play() + state */ }
    func next() { /* queue.advance → loadAndPlay или stop в конце */ }
    func previous() { /* если currentTime > 3с — seek(0), иначе queue.goBack */ }
    func seek(to seconds: Double) { /* stop player, scheduleSegment с кадра, play */ }

    private func loadAndPlay(_ track: Track) {
        // 1. file = AVAudioFile(forReading: track.url)
        // 2. План частоты: engine.stop();
        //    let plan = SampleRateCoordinator.prepare(session: session,
        //                                             fileRate: file.fileFormat.sampleRate)
        //    try AVAudioSession.sharedInstance().setActive(true)
        // 3. Пересбор графа: engine.disconnectNodeOutput(player)
        //    engine.connect(player, to: engine.mainMixerNode,
        //                   format: file.processingFormat)
        // 4. player.scheduleFile(file, at: nil,
        //                        completionCallbackType: .dataPlayedBack) { [weak self] _ in
        //        Task { @MainActor in self?.handleTrackFinished() }   // → next()
        //    }
        //    Обязательно .dataPlayedBack: legacy-completion срабатывает при
        //    ПОТРЕБЛЕНИИ данных нодой, до проигрывания хвоста — stop() в next()
        //    обрезал бы конец трека.
        // 5. engine.prepare(); try engine.start(); player.play(); state = .playing
        // 6. Таймер 0.5с обновляет currentTime из player.lastRenderTime
        //    (playerTime(forNodeTime:) + startFrame) / sampleRate
    }
}
```
Полные реализации методов написать по комментариям; обработать ошибки открытия файла (пропуск трека → next()). Completion-handler у `scheduleFile`/`scheduleSegment` (даже с `.dataPlayedBack`) вызывается и при ручном `player.stop()` — отличать «дослушан» от «остановлен» (generation-счётчик или флаг), иначе next() сработает при seek. После `try? engine.start()` в togglePlayPause/seek обязательно `guard engine.isRunning` перед `player.play()` — play() на незапущенном движке кидает NSException.

**Step 3: Подключить к ContentView** временно: кнопка «Сканировать Documents» → `LibraryScanner.scan` → список треков → тап → `engine.play(tracks:startAt:)`. Собрать, запустить в симуляторе, закинуть фикстурный FLAC через drag-drop в окно симулятора (падает в Files) или `xcrun simctl addmedia` не подходит для аудио — проще: добавить в Documents через `xcrun simctl get_app_container booted dev.zver.ZverIOS data` и `cp` в `Documents/`.

Expected: трек играет в симуляторе, по окончании — следующий.

**Step 4: Commit** — `feat: PlayerEngine — AVAudioEngine, sample-rate matching, очередь`

---

## Task 10: NowPlayingService — локскрин и системные команды

**Files:**
- Create: `Apps/ZverIOS/Sources/Audio/NowPlayingService.swift`
- Modify: `Apps/ZverIOS/Sources/Audio/PlayerEngine.swift` (вызовы обновления)

**Step 1: Реализация**

```swift
import MediaPlayer
import ZverCore

@MainActor
final class NowPlayingService {
    // MPRemoteCommandCenter — глобальный синглтон: захватываем движок
    // только weak, токены addTarget сохраняем и снимаем в unwire()/deinit,
    // wire() идемпотентен (повторный вызов не плодит дубли обработчиков).
    // @unchecked Sendable — nonisolated deinit в Swift 6 не может читать
    // non-Sendable stored property; removeTarget зовём через хоп на MainActor.
    private struct CommandRegistration: @unchecked Sendable {
        let command: MPRemoteCommand
        let token: Any
    }
    private var commandTargets: [CommandRegistration] = []

    deinit {
        let targets = commandTargets
        guard !targets.isEmpty else { return }
        Task { @MainActor in for r in targets { r.command.removeTarget(r.token) } }
    }

    func wire(to engine: PlayerEngine) {
        unwire()
        let cc = MPRemoteCommandCenter.shared()
        register(cc.playCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            engine.resume(); return .success
        }
        register(cc.pauseCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            engine.pause(); return .success
        }
        register(cc.nextTrackCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            engine.next(); return .success
        }
        register(cc.previousTrackCommand) { [weak engine] _ in
            guard let engine else { return .commandFailed }
            engine.previous(); return .success
        }
        register(cc.changePlaybackPositionCommand) { [weak engine] e in
            guard let engine,
                  let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime // e не Sendable — внутрь только Double
            engine.seek(to: position); return .success
        }
    }

    func unwire() {
        for r in commandTargets { r.command.removeTarget(r.token) }
        commandTargets.removeAll()
    }

    private func register(_ command: MPRemoteCommand,
                          handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        commandTargets.append(.init(command: command, token: command.addTarget(handler: handler)))
    }

    func update(track: Track, artwork: UIImage?, currentTime: Double, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist ?? "",
            MPMediaItemPropertyAlbumTitle: track.album ?? "",
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] =
                MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
```
Вызывать `update` при смене трека, play/pause и seek (НЕ каждые 0.5с — системе достаточно elapsed+rate, она экстраполирует). Swift 6: addTarget-замыкания приходят на главном потоке, но без аннотации MainActor — вызовы движка оборачивать в `MainActor.assumeIsolated { ... }`; из не-Sendable события (`MPChangePlaybackPositionCommandEvent`) внутрь изолированного замыкания передавать только извлечённый `positionTime: Double`.

**Step 2:** Билд → SUCCEEDED. **Step 3: Commit** — `feat: локскрин и системный пульт (MPNowPlaying/RemoteCommand)`

---

## Task 11: UI — библиотека (список по альбомам)

**Files:**
- Create: `Apps/ZverIOS/Sources/Library/LibraryStore.swift` — `@MainActor ObservableObject`: скан Documents при старте и по pull-to-refresh, группировка `[Track]` → `[(album: String, tracks: [Track])]` (сортировка: альбом по алфавиту, треки по trackNumber)
- Create: `Apps/ZverIOS/Sources/Library/LibraryView.swift` — `List` с секциями-альбомами, ряд трека: title + sampleRate/bitDepth бейдж («24/96»), тап → play
- Modify: `ContentView.swift` — LibraryView вместо заглушки

Группировку (чистая функция) — в ZverCore с тестом:

```swift
@Test func groupsTracksByAlbumSortedByTrackNumber() { ... }
```

**Step:** тест группировки → FAIL → реализация → PASS → билд приложения → SUCCEEDED → Commit — `feat: экран библиотеки с группировкой по альбомам`

---

## Task 12: UI — полноэкранный плеер и мини-плеер

**Files:**
- Create: `Apps/ZverIOS/Sources/Player/MiniPlayerBar.swift` — полоска над нижним краем: артворк-миниатюра, title, play/pause, прогресс тонкой линией; тап → fullscreen
- Create: `Apps/ZverIOS/Sources/Player/PlayerScreen.swift` — `.sheet`/`fullScreenCover`: крупный артворк, title/artist/album, бейдж формата («FLAC 24/96»), слайдер-прогресс с seek (drag → seek по отпусканию), кнопки prev/play/next, свайп вниз закрывает (системное поведение sheet)
- Modify: `ContentView.swift` — ZStack: LibraryView + MiniPlayerBar снизу (показан, когда `engine.queue.current != nil`)

Артворк: грузить через `MetadataReader` лениво при смене трека, кэш в `LibraryStore` (NSCache по track.id).

**Step:** билд → SUCCEEDED → ручная проверка в симуляторе (играет, мини-плеер появляется, шторка открывается/закрывается, seek работает) → Commit — `feat: полноэкранный плеер и мини-плеер`

---

## Task 13: Устойчивость аудиосессии (ЦАП, звонки)

**Files:**
- Modify: `Apps/ZverIOS/Sources/Audio/PlayerEngine.swift`

**Step 1:** Подписки в init:
- `AVAudioSession.routeChangeNotification`: причина `.oldDeviceUnavailable` (выдернули ЦАП/наушники) → `pause()`; `.newDeviceAvailable` → пересобрать граф под новую частоту при следующем play
- `AVAudioSession.interruptionNotification`: `.began` → pause; `.ended` с `.shouldResume` → play
- `engine.configurationChangeNotification` → пересбор графа

**Step 2:** Билд → SUCCEEDED. Ручная проверка на маке невозможна — войдёт в чеклист Task 14.
**Step 3: Commit** — `feat: обработка route change и interruption`

---

## Task 14: Деплой на устройство и ручной чеклист

**Files:**
- Create: `docs/manual-test-checklist.md`
- Modify: `README.md` (раздел установки)

**Step 1: README — установка на iPhone:** открыть `ZverIOS.xcodeproj`, выбрать Personal Team в Signing, выбрать устройство, Run; на телефоне Settings → General → VPN & Device Management → доверять профилю. Для авто-переподписи — AltStore (AltServer на Маке, та же Wi-Fi).

**Step 2: Чеклист ручной проверки (выполняет пользователь):**

```markdown
# Ручная проверка на железе
- [ ] Импорт: закинуть FLAC-альбом через Files app в папку Zver → появился в библиотеке
- [ ] Воспроизведение FLAC 16/44.1 и hi-res 24/96+
- [ ] ЦАП: индикатор частоты на ЦАПе показывает частоту ТРЕКА (44.1 → 96 при смене)
- [ ] Локскрин: артворк, прогресс, play/pause/next работают
- [ ] Фон: свернуть приложение — музыка играет дальше
- [ ] Конец трека → авто-переход на следующий
- [ ] Seek в полноэкранном плеере и с локскрина
- [ ] Выдернуть ЦАП во время игры → пауза, не краш, ни секунды звука из динамика
- [ ] Входящий звонок → пауза, после звонка продолжилось
- [ ] Убить приложение, открыть → библиотека на месте (скан Documents)
```

**Step 3: Commit** — `docs: установка и чеклист ручной проверки этапа 1`

---

## Definition of Done этапа 1

Все тесты пакетов зелёные (`swift test` × 2), приложение собирается без warnings в концепции «treat warnings as errors» не настаиваем, ставится на iPhone 12 mini, пользователь прошёл чеклист Task 14. После этого — этап 2 «Каталог и библиотека» (GRDB, экраны артистов, gapless, плейлисты) отдельным планом.
