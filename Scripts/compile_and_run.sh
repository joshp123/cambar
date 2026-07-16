#!/usr/bin/env bash
# Kill running instances, package, relaunch, verify.
set -euo pipefail

unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS
export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=CamBar
APP_BUNDLE="${HOME}/Applications/${APP_NAME}.app"
APP_PROCESS_PATTERN="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
GO2RTC_APP_PATTERN="${APP_BUNDLE}/Contents/Resources/bin/go2rtc"
RUN_TESTS=0

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "${arg}" in
    --test|-t) RUN_TESTS=1 ;;
    --help|-h)
      log "Usage: $(basename "$0") [--test]"
      exit 0
      ;;
  esac
done

command -v go2rtc >/dev/null 2>&1 || fail "go2rtc not found on PATH; refusing to stop the working app before packaging can succeed."

if [[ "${RUN_TESTS}" == "1" ]]; then
  log "==> swift test"
  swift test -q
fi

log "==> Killing existing ${APP_NAME} instances"
pkill -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
pkill -f "${GO2RTC_APP_PATTERN}" 2>/dev/null || true

log "==> package app"
"${ROOT_DIR}/Scripts/package_app.sh" release

log "==> launch app"
if ! open -g -n "${APP_BUNDLE}"; then
  log "WARN: open failed; launching binary directly."
  "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1 &
  disown
fi

for _ in {1..10}; do
  if pgrep -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1; then
    log "OK: ${APP_NAME} is running."
    exit 0
  fi
  sleep 0.4
done
fail "App exited immediately. Check crash logs in Console.app (User Reports)."
