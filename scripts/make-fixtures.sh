#!/bin/bash
# Генерирует эталонные аудиофайлы для тестов ZverMetadata.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)/Packages/ZverMetadata/Tests/ZverMetadataTests/Fixtures"
mkdir -p "$DIR"; cd "$DIR"

# 1 секунда синуса 440 Гц
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 44100 -sample_fmt s16 tagged_16_44.flac
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 96000 -af aformat=sample_fmts=s32 -bits_per_raw_sample 24 hires_24_96.flac
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 44100 -sample_fmt s16 notags.flac
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=1" -ar 44100 -c:a alac alac.m4a

# Vorbis-теги
metaflac --set-tag="TITLE=Тестовый трек" --set-tag="ARTIST=Зверь" --set-tag="ALBUM=Фикстуры" --set-tag="TRACKNUMBER=3" --set-tag="DATE=2024" tagged_16_44.flac
metaflac --set-tag="TITLE=Hi-Res" --set-tag="ARTIST=Зверь" --set-tag="ALBUM=Фикстуры" hires_24_96.flac

# Обложка: 1x1 красный PNG из base64 (без зависимостей)
echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" | base64 -d > cover.png
metaflac --import-picture-from=cover.png tagged_16_44.flac
rm cover.png

# Длинная фикстура для UI-смоук-теста (PlaybackSmokeTests): 8 секунд, чтобы
# обложка успевала загрузиться, пока трек ещё играет (на 1-секундном треке
# краш-путь Now Playing с артворком не успевает выполниться). Кладётся
# в Documents приложения на симуляторе:
#   xcrun simctl get_app_container booted dev.zver.ZverIOS data
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=8" -ar 44100 -sample_fmt s16 ui_smoke.flac
metaflac --set-tag="TITLE=Длинный трек" --set-tag="ARTIST=Зверь" --set-tag="ALBUM=Фикстуры" --set-tag="TRACKNUMBER=9" ui_smoke.flac
echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==" | base64 -d > cover.png
metaflac --import-picture-from=cover.png ui_smoke.flac
rm cover.png

# Контроль
metaflac --list --block-type=STREAMINFO hires_24_96.flac | grep -E "sample_rate|bits-per-sample"
afinfo alac.m4a | head -5
