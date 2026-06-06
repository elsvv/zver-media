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

## Установка на iPhone

1. Сгенерировать проект и открыть его в Xcode:

   ```bash
   cd Apps/ZverIOS && xcodegen generate
   open ZverIOS.xcodeproj
   ```

2. В таргете ZverIOS → **Signing & Capabilities** выбрать **Personal Team**
   (достаточно бесплатного Apple ID, добавляется в Xcode → Settings → Accounts).
3. Подключить iPhone, выбрать его как destination и нажать **Run**.
4. На телефоне разрешить запуск: **Settings → General → VPN & Device
   Management** → доверять профилю разработчика.

### Авто-переподпись через AltStore

Профиль бесплатного Apple ID живёт 7 дней. Чтобы не переподписывать вручную,
поставь [AltStore](https://altstore.io): AltServer на Маке продлевает профиль
автоматически, пока iPhone и Мак в одной Wi-Fi сети. Ограничение free Apple ID —
максимум 3 sideload-приложения одновременно.

После установки пройди [чеклист ручной проверки](docs/manual-test-checklist.md).

## Тесты пакетов

Пакеты — чистая логика, тестируются на macOS без симулятора:

```bash
cd Packages/ZverCore && swift test
cd Packages/ZverMetadata && swift test
```

## Тулчейн

Xcode 16+, `xcodegen`, `ffmpeg`, `metaflac` (`brew install xcodegen ffmpeg flac`).
