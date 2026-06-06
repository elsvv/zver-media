# Zver Cloud

Личная система синхронизации и воспроизведения lossless/hi-res музыки:
нативный iOS-плеер с выводом на USB ЦАП + Mac-компаньон (заливка альбомов,
метадата, пульт) + Яндекс.Диск как холодный ярус хранения.

Сейчас реализуется **этап 1 «Ядро плеера»** — iOS-приложение, которое играет
FLAC/ALAC из Documents, переключает sample rate USB ЦАПа под трек и
управляется с локскрина.

Документы:
- [Дизайн системы](docs/plans/2026-06-06-zver-cloud-design.md)
- [План этапа 1](docs/plans/2026-06-06-stage1-player-core.md)

## Структура

```
Packages/ZverCore/      — SPM: модели, очередь воспроизведения, координатор частоты
Packages/ZverMetadata/  — SPM: парсинг тегов (Vorbis-комменты), сканер папки
Apps/ZverIOS/           — iOS-приложение (XcodeGen, проект генерируется из project.yml)
docs/plans/             — дизайн и implementation-планы
scripts/                — вспомогательные скрипты
```

## Сборка

`ZverIOS.xcodeproj` не хранится в git — генерируется XcodeGen:

```bash
cd Apps/ZverIOS && xcodegen generate
xcodebuild -project Apps/ZverIOS/ZverIOS.xcodeproj -scheme ZverIOS \
  -destination "platform=iOS Simulator,name=iPhone SE (3rd generation)" build
```

## Тесты пакетов

Пакеты — чистая логика, тестируются на macOS без симулятора:

```bash
cd Packages/ZverCore && swift test
cd Packages/ZverMetadata && swift test
```

## Тулчейн

Xcode 16+, `xcodegen`, `ffmpeg`, `metaflac` (`brew install xcodegen ffmpeg flac`).
