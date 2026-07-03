#!/usr/bin/env bash
#
# deploy-ios.sh — собрать ZverIOS и обновить его на подключённом iPhone.
#
# Ничего не захардкожено: устройство (UDID) находится динамически, проект
# пересобирается (xcodegen), приложение собирается под девайс с авто-подписью,
# ставится через devicectl и запускается. Работает из любой директории.
#
# Использование:
#   scripts/deploy-ios.sh                  # первый подключённый iPhone/iPad
#   scripts/deploy-ios.sh "Viacheslav"     # выбрать устройство по подстроке имени/UDID
#   ZVER_IOS_DEVICE=00008101-… scripts/deploy-ios.sh
#   NO_LAUNCH=1 scripts/deploy-ios.sh      # поставить, но не запускать
#   CONFIGURATION=Release scripts/deploy-ios.sh
#
# Переменные окружения (все опциональны):
#   ZVER_IOS_DEVICE  имя/UDID (подстрока) нужного устройства (или 1-й аргумент)
#   SCHEME           схема Xcode           (по умолчанию: ZverIOS)
#   CONFIGURATION    Debug|Release         (по умолчанию: Debug)
#   NO_LAUNCH=1      не запускать после установки

set -euo pipefail

# ── вывод ────────────────────────────────────────────────────────────────
info() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

case "${1:-}" in -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0;; esac

# ── пути и конфиг ────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/../Apps/ZverIOS"
[ -d "$APP_DIR" ] || die "не нашёл Apps/ZverIOS рядом со скриптом ($APP_DIR)"
APP_DIR="$(cd "$APP_DIR" && pwd)"

SCHEME="${SCHEME:-ZverIOS}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED="$APP_DIR/build/DerivedData"
PROJECT="$APP_DIR/$SCHEME.xcodeproj"

command -v xcodebuild >/dev/null 2>&1 || die "нет xcodebuild — поставь Xcode + Command Line Tools"
command -v xcrun      >/dev/null 2>&1 || die "нет xcrun — поставь Xcode"

# ── 1. найти устройство ──────────────────────────────────────────────────
info "Ищу подключённый iPhone/iPad…"
FILTER="${1:-${ZVER_IOS_DEVICE:-}}"

# Берём ТОЛЬКО онлайн-физические устройства: строки внутри блока «== Devices ==»
# (до «== Devices Offline ==» / «== Simulators ==»), только iPhone/iPad.
# Формат строки xctrace:  Name (iOS ver) (UDID)
DEVICES="$(
  xcrun xctrace list devices 2>/dev/null \
    | awk '/^== Devices ==/{f=1;next} /^== /{f=0} f' \
    | grep -Ei 'iphone|ipad' \
    | grep -E '\([0-9A-Fa-f-]{25,40}\)[[:space:]]*$' || true
)"
[ -n "$DEVICES" ] || die "не вижу онлайн iPhone/iPad. Подключи телефон (USB/Wi-Fi), разблокируй и подтверди «Доверять этому компьютеру»."

if [ -n "$FILTER" ]; then
  DEVICES="$(printf '%s\n' "$DEVICES" | grep -i -- "$FILTER" || true)"
  [ -n "$DEVICES" ] || die "нет устройства по фильтру «${FILTER}» среди подключённых."
fi

if [ "$(printf '%s\n' "$DEVICES" | grep -c .)" -gt 1 ]; then
  warn "подключено несколько устройств — беру первое (уточни фильтром/ZVER_IOS_DEVICE):"
  printf '%s\n' "$DEVICES" | sed 's/^/    /' >&2
fi

LINE="$(printf '%s\n' "$DEVICES" | head -1)"
UDID="$(printf '%s\n' "$LINE" | sed -E 's/.*\(([^()]+)\)[[:space:]]*$/\1/')"
printf '%s' "$UDID" | grep -Eq '^[0-9A-Fa-f-]{25,40}$' || die "не смог извлечь UDID из строки: $LINE"
DEV_NAME="$(printf '%s\n' "$LINE" | sed -E 's/ *\([^()]*\) *\([^()]*\) *$//')"
ok "Устройство: ${DEV_NAME:-iPhone}  [$UDID]"

# ── 2. пересобрать проект (подхватить новые файлы) ───────────────────────
if command -v xcodegen >/dev/null 2>&1; then
  info "xcodegen generate…"
  ( cd "$APP_DIR" && xcodegen generate >/dev/null ) && ok "проект пересобран"
elif [ -d "$PROJECT" ]; then
  warn "xcodegen не установлен (brew install xcodegen) — собираю существующий проект; новые файлы могут не попасть."
else
  die "нет ни xcodegen, ни $PROJECT. Установи: brew install xcodegen"
fi

# ── 3. сборка под устройство с авто-подписью ─────────────────────────────
info "Сборка $SCHEME ($CONFIGURATION) под устройство… (несколько минут в первый раз)"
LOG="$(mktemp -t zver-ios-build.XXXXXX)"
if ! xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" \
      -destination "id=$UDID" \
      -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates \
      -allowProvisioningDeviceRegistration \
      build >"$LOG" 2>&1; then
  warn "сборка упала — релевантные строки:"
  grep -E 'error:|Provisioning|Signing|development team|No profiles|requires' "$LOG" | tail -20 >&2 || tail -30 "$LOG" >&2
  die "сборка не прошла (полный лог: $LOG)"
fi
rm -f "$LOG"
ok "собрано и подписано"

# ── 4. найти собранный .app ──────────────────────────────────────────────
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/$SCHEME.app"
[ -d "$APP" ] || APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name '*.app' -type d 2>/dev/null | head -1)"
[ -d "$APP" ] || die "не нашёл собранный .app под $DERIVED"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || true)"

# ── 5. установка ─────────────────────────────────────────────────────────
info "Установка на ${DEV_NAME:-iPhone}…"
xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null \
  || die "установка не удалась. Телефон разблокирован? Профиль разработчика доверен (Настройки → Основные → VPN и управление устройством)?"
ok "установлено"

# ── 6. запуск ────────────────────────────────────────────────────────────
if [ "${NO_LAUNCH:-0}" != "1" ] && [ -n "$BUNDLE_ID" ]; then
  info "Запуск ${BUNDLE_ID}…"
  if xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    ok "запущено"
  else
    warn "не удалось автозапустить (первый запуск требует доверия профилю?) — открой приложение вручную."
  fi
fi

printf '\033[1;32m✅ Готово: %s → %s\033[0m\n' "$SCHEME" "${DEV_NAME:-iPhone}"
