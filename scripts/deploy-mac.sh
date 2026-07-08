#!/usr/bin/env bash
#
# deploy-mac.sh — собрать ZverMac и обновить установленную копию в /Applications.
#
# Аналог deploy-ios.sh для десктопа. Ничего не захардкожено: проект
# пересобирается (xcodegen), приложение собирается, ставится в /Applications
# (заменяя старую копию) и запускается. Работает из любой директории.
#
# Зачем: сборка сама по себе кладёт .app только в DerivedData — приложение,
# которое пользователь реально запускает из /Applications, при этом остаётся
# СТАРЫМ. Этот скрипт закрывает разрыв: «пересобрал» = «обновил то, что запускаю».
#
# Использование:
#   scripts/deploy-mac.sh                   # собрать Debug и поставить в /Applications
#   CONFIGURATION=Release scripts/deploy-mac.sh
#   NO_LAUNCH=1 scripts/deploy-mac.sh       # поставить, но не запускать
#   DEST_DIR=~/Applications scripts/deploy-mac.sh
#
# Переменные окружения (все опциональны):
#   SCHEME         схема Xcode         (по умолчанию: ZverMac)
#   CONFIGURATION  Debug|Release       (по умолчанию: Debug)
#   DEST_DIR       куда ставить .app   (по умолчанию: /Applications)
#   NO_LAUNCH=1    не запускать после установки

set -euo pipefail

# ── вывод ────────────────────────────────────────────────────────────────
info() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

case "${1:-}" in -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0;; esac

# ── пути и конфиг ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/../Apps/ZverMac"
[ -d "$APP_DIR" ] || die "не нашёл Apps/ZverMac рядом со скриптом ($APP_DIR)"
APP_DIR="$(cd "$APP_DIR" && pwd)"

SCHEME="${SCHEME:-ZverMac}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DEST_DIR="${DEST_DIR:-/Applications}"
DERIVED="$APP_DIR/build/DerivedData"
PROJECT="$APP_DIR/$SCHEME.xcodeproj"

command -v xcodebuild >/dev/null 2>&1 || die "нет xcodebuild — поставь Xcode + Command Line Tools"

# ── 1. пересобрать проект (подхватить новые файлы) ───────────────────────
if command -v xcodegen >/dev/null 2>&1; then
  info "xcodegen generate…"
  ( cd "$APP_DIR" && xcodegen generate >/dev/null ) && ok "проект пересобран"
elif [ -d "$PROJECT" ]; then
  warn "xcodegen не установлен (brew install xcodegen) — собираю существующий проект; новые файлы могут не попасть."
else
  die "нет ни xcodegen, ни $PROJECT. Установи: brew install xcodegen"
fi

# ── 2. сборка ────────────────────────────────────────────────────────────
info "Сборка $SCHEME ($CONFIGURATION) под macOS…"
LOG="$(mktemp -t zver-mac-build.XXXXXX)"
if ! xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED" \
      build >"$LOG" 2>&1; then
  warn "сборка упала — релевантные строки:"
  grep -E 'error:|Signing|development team|requires' "$LOG" | tail -20 >&2 || tail -30 "$LOG" >&2
  die "сборка не прошла (полный лог: $LOG)"
fi
rm -f "$LOG"
ok "собрано"

# ── 3. найти собранный .app ──────────────────────────────────────────────
APP="$DERIVED/Build/Products/$CONFIGURATION/$SCHEME.app"
[ -d "$APP" ] || APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name "$SCHEME.app" -type d 2>/dev/null | head -1)"
[ -d "$APP" ] || die "не нашёл собранный .app под $DERIVED"

# ── 4. установка в /Applications (замена старой копии) ────────────────────
DEST="$DEST_DIR/$SCHEME.app"
info "Установка в ${DEST}…"
# Закрыть запущенную копию, иначе замена бинарника не подхватится до перезапуска.
osascript -e "tell application \"$SCHEME\" to quit" >/dev/null 2>&1 || true
rm -rf "$DEST" || die "не смог удалить старую $DEST (нет прав? запусти с нужными правами на $DEST_DIR)"
ditto "$APP" "$DEST" || die "не смог скопировать .app в $DEST"
ok "установлено ($(stat -f '%Sm' "$DEST/Contents/MacOS/$SCHEME" 2>/dev/null))"

# ── 5. запуск ────────────────────────────────────────────────────────────
if [ "${NO_LAUNCH:-0}" != "1" ]; then
  info "Запуск ${SCHEME}…"
  open -a "$DEST" && ok "запущено" || warn "не удалось автозапустить — открой вручную."
fi

printf '\033[1;32m✅ Готово: %s → %s\033[0m\n' "$SCHEME" "$DEST"
