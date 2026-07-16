#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$HOME/Applications/CamBar.app"
EXECUTABLE="$APP/Contents/MacOS/CamBar"
HELPER="$APP/Contents/Resources/bin/go2rtc"
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
if pgrep -f "$HELPER" >/dev/null; then
  fail "CamBar's bundled go2rtc is already running without the app"
fi

PREVIOUS_SESSION=""
if [[ -f "$LOG" ]]; then
  PREVIOUS_SESSION=$(jq -r 'select(.event == "launch" and .session_id != null) | .session_id' "$LOG" | tail -n 1)
fi
cleanup_failed_canary() {
  local exit_code=$?
  trap - EXIT INT TERM
  pkill -f "$EXECUTABLE" >/dev/null 2>&1 || true
  pkill -f "$HELPER" >/dev/null 2>&1 || true
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
CANARY_SESSION=$(jq -r 'select(.event == "launch" and .session_id != null) | .session_id' "$LOG" | tail -n 1)
if [[ -z "$CANARY_SESSION" || "$CANARY_SESSION" == "$PREVIOUS_SESSION" ]]; then
  fail "CamBar produced no fresh launch event and was stopped"
fi
if jq -e --arg session "$CANARY_SESSION" '
  select(
    .session_id == $session
    and (
      .event == "menu_open_requested"
      or .event == "menu_will_show"
      or .event == "menu_did_show"
      or .event == "window_open_requested"
    )
  )
' "$LOG" >/dev/null; then
  fail "CamBar presented UI without user input and was stopped"
fi

trap - EXIT INT TERM
echo "Automatic presentation canary passed; CamBar is running."
echo "Manually click the status icon twice and confirm it opens once, then closes once."
echo "Emergency stop: pkill -f '$EXECUTABLE'"
echo "Then stop its helper: pkill -f '$HELPER'"
