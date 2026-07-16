#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$HOME/Applications/CamBar.app"
EXECUTABLE="$APP/Contents/MacOS/CamBar"
LOG="$HOME/Library/Caches/CamBar/direct/direct-stream-events.jsonl"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$APP" ]] || fail "CamBar is not installed at $APP"
[[ -x "$EXECUTABLE" ]] || fail "CamBar executable is missing"
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] || fail "working tree is dirty"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "$APP/Contents/Info.plist")" == "$(git -C "$ROOT" rev-parse --short HEAD)" ]] || fail "installed app does not match HEAD"
if pgrep -f "$EXECUTABLE" >/dev/null; then
  fail "CamBar is already running"
fi

LOG_SIZE_BEFORE=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
cleanup_failed_canary() {
  local exit_code=$?
  trap - EXIT INT TERM
  pkill -f "$EXECUTABLE" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap cleanup_failed_canary EXIT INT TERM

open -gj -n "$APP"
sleep 5

if ! pgrep -f "$EXECUTABLE" >/dev/null; then
  fail "CamBar exited during the five-second canary"
fi

if [[ ! -f "$LOG" ]]; then
  fail "CamBar produced no telemetry and was stopped"
fi
LOG_SIZE_AFTER=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
if (( LOG_SIZE_AFTER < LOG_SIZE_BEFORE )); then
  LOG_SIZE_BEFORE=0
fi
if ! tail -c "+$((LOG_SIZE_BEFORE + 1))" "$LOG" | rg -q '"event":"launch"'; then
  fail "CamBar produced no fresh launch event and was stopped"
fi
if tail -c "+$((LOG_SIZE_BEFORE + 1))" "$LOG" | rg -q '"event":"(menu_open_requested|menu_will_show|menu_did_show|window_open_requested)"'; then
  fail "CamBar presented UI without user input and was stopped"
fi

trap - EXIT INT TERM
echo "Automatic presentation canary passed; CamBar is running."
echo "Manually click the status icon twice and confirm it opens once, then closes once."
echo "Emergency stop: pkill -f '$EXECUTABLE'"
