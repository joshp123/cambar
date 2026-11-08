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

# The app must start and open nothing by itself.
session=""
for _ in {1..20}; do
  sleep 0.5
  session=$(jq -r 'select(.event == "launch") | .session_id' "$LOG" 2>/dev/null | tail -n 1 || true)
  [[ -n "$session" && "$session" != "$previous_session" ]] && break
done
[[ -n "$session" && "$session" != "$previous_session" ]] || fail "CamBar did not start"
sleep 3
if jq -e --arg s "$session" 'select(.session_id == $s and
    (.event | test("^(menu_open_requested|menu_did_show|window_open_requested)$")))' "$LOG" >/dev/null; then
  pkill -KILL -f "$EXECUTABLE"
  fail "CamBar opened UI without a click and was stopped"
fi
echo "Installed and restarted $APP ($(git rev-parse --short HEAD))."

# Check the stream with the installed binary's headless probe: the same code
# as the app, measured the same way whatever the Mac's power mode. Targets
# (Josh: never "ownzone" the CPU again): menu closed at most 3% of one core and
# 150 MB; opening shows live video in under 500 ms.
probe=$(CAMBAR_LOW_POWER_MODE=0 "$EXECUTABLE" --probe 20 2>/dev/null) || true
[[ -n "$probe" ]] || fail "probe produced no summary"
result=$(jq -r .result <<<"$probe")
cpu=$(jq -r '.hidden_cpu_percent // 99' <<<"$probe")
memory=$(jq -r '.memory_mb // 9999' <<<"$probe")
open_ms=$(jq -r '.reveal_ms // [9999] | sort | .[length / 2 | floor]' <<<"$probe")
echo "Route $(jq -r .route <<<"$probe"); live: $result; menu closed: ${cpu}% CPU, ${memory} MB; open to live: ${open_ms} ms (median of five)."
[[ "$result" == "live" ]] || fail "no live video"
awk -v c="$cpu" -v m="$memory" -v o="$open_ms" 'BEGIN { exit !(c <= 3 && m <= 150 && o <= 500) }' \
  || fail "target missed: ${cpu}% CPU (max 3), ${memory} MB (max 150), ${open_ms} ms to live (max 500)"
