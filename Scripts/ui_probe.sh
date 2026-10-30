#!/usr/bin/env bash
# Runs the real popover content and video surface in an invisible off-screen
# window, from the signed bundle in the background, and fails if CamBar ever
# becomes the frontmost app. Prints the probe's JSON summary.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
APP="$ROOT/.build/package/CamBar.app"
OUT=$(mktemp -d)

"$ROOT/Scripts/package_app.sh" release >/dev/null

open -gj -n --stdout "$OUT/summary.json" --stderr "$OUT/telemetry.jsonl" "$APP" --args --ui-probe
stole_focus=0
for _ in {1..180}; do  # 90 seconds at most
  lsappinfo info -only name "$(lsappinfo front)" | grep -q '"CamBar"' && stole_focus=1
  [[ -s "$OUT/summary.json" ]] && break
  sleep 0.5
done
pkill -f "$APP/Contents/MacOS/CamBar" 2>/dev/null || true

cat "$OUT/summary.json"
echo "telemetry: $OUT/telemetry.jsonl"
[[ "$stole_focus" == 0 ]] || { echo "ERROR: CamBar became the frontmost app" >&2; exit 1; }
[[ -s "$OUT/summary.json" ]] || { echo "ERROR: probe produced no summary" >&2; exit 1; }
