#!/usr/bin/env bash
# Test, build, install and restart CamBar in the background, then confirm from
# its log that live video arrived and that it opened no UI by itself.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
APP="$HOME/Applications/CamBar.app"
EXECUTABLE="$APP/Contents/MacOS/CamBar"
LOG="$HOME/Library/Caches/CamBar/direct/direct-stream-events.jsonl"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain --untracked-files=all)" ]] \
  || fail "commit first, so the installed build matches a real commit"

swift test -q
"$ROOT/Scripts/package_app.sh" release

pkill -TERM -f "$EXECUTABLE" 2>/dev/null || true
for _ in {1..50}; do pgrep -f "$EXECUTABLE" >/dev/null || break; sleep 0.1; done
pgrep -f "$EXECUTABLE" >/dev/null && fail "running CamBar did not quit"

# Update the bundle in place: a stable path and signature keep the Local
# Network permission and login item attached to the same app.
mkdir -p "$APP"
rsync -a --delete "$ROOT/.build/package/CamBar.app/" "$APP/"
codesign --verify --deep --strict "$APP"

previous_session=$(jq -r 'select(.event == "launch") | .session_id' "$LOG" 2>/dev/null | tail -n 1 || true)
open -gj "$APP"

session=""
first_frame=""
for _ in {1..30}; do
  sleep 0.5
  session=$(jq -r 'select(.event == "launch") | .session_id' "$LOG" 2>/dev/null | tail -n 1 || true)
  [[ -n "$session" && "$session" != "$previous_session" ]] || continue
  first_frame=$(jq -r --arg s "$session" \
    'select(.session_id == $s and .event == "first_frame") | .elapsed_ms' "$LOG" | head -n 1)
  [[ -n "$first_frame" ]] && break
done
[[ -n "$session" && "$session" != "$previous_session" ]] || fail "CamBar did not start"

if jq -e --arg s "$session" 'select(.session_id == $s and
    (.event | test("^(menu_open_requested|menu_did_show|window_open_requested)$")))' "$LOG" >/dev/null; then
  pkill -KILL -f "$EXECUTABLE"
  fail "CamBar opened UI without a click and was stopped"
fi

echo "Installed and restarted $APP ($(git rev-parse --short HEAD))."
if [[ -z "$first_frame" ]]; then
  echo "ERROR: CamBar is running but showed no video within 15 s. Last stream event:" >&2
  jq -r --arg s "$session" 'select(.session_id == $s and .component == "stream") | "\(.event) \(.detail // "")"' "$LOG" | tail -n 1 >&2
  exit 1
fi
echo "Live video after ${first_frame} ms."

# Resource target with the menu closed (Josh: never "ownzone" the CPU again):
# at most 3% of one core and 150 MB. The second heartbeat after the first
# frame excludes startup.
heartbeat=""
for _ in {1..30}; do
  sleep 1
  heartbeat=$(jq -r --arg s "$session" \
    'select(.session_id == $s and .event == "frame_heartbeat") | .detail' "$LOG" | sed -n 2p)
  [[ -n "$heartbeat" ]] && break
done
[[ -n "$heartbeat" ]] || fail "no frame heartbeat to measure resources"
cpu=$(sed -E 's/.*cpu_percent=([0-9.]+).*/\1/' <<<"$heartbeat")
memory=$(sed -E 's/.*memory_mb=([0-9]+).*/\1/' <<<"$heartbeat")
echo "Warm stream: ${cpu}% CPU, ${memory} MB ($(sed -E 's/.*(stream=[a-z]+ real_time_ratio=[0-9.]+).*/\1/' <<<"$heartbeat"))."
awk -v c="$cpu" -v m="$memory" 'BEGIN { exit !(c <= 3 && m <= 150) }' \
  || fail "resource target missed: ${cpu}% CPU (max 3), ${memory} MB (max 150)"
