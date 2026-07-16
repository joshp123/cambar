#!/usr/bin/env bash
# Build, launch, auto-open the popover, and fail if the WebView snapshot is blank.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME=${APP_NAME:-CamBar}
APP_BUNDLE="${ROOT_DIR}/${APP_NAME}.app"
APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
OUT_DIR="${OUT_DIR:-${TMPDIR:-/tmp}/cambar-popover-debug-$(date +%Y%m%d-%H%M%S)}"
TELEMETRY="${HOME}/Library/Caches/CamBar/direct/direct-stream-events.jsonl"
GO2RTC_LOG="${HOME}/Library/Caches/CamBar/go2rtc/go2rtc.log"
POPOVER_CYCLES="${POPOVER_CYCLES:-4}"
POPOVER_VISIBLE_SECONDS="${POPOVER_VISIBLE_SECONDS:-3}"
POPOVER_START_DELAY_SECONDS="${POPOVER_START_DELAY_SECONDS:-3}"
APP_PID=""

log() { printf '%s\n' "$*"; }
collect_artifacts() {
  mkdir -p "$OUT_DIR" 2>/dev/null || true
  cp "$TELEMETRY" "$OUT_DIR/direct-stream-events.jsonl" 2>/dev/null || true
  cp "$GO2RTC_LOG" "$OUT_DIR/go2rtc.log" 2>/dev/null || true
}
fail() {
  collect_artifacts
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
cleanup() {
  set +e
  collect_artifacts
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  pkill -f "${APP_NAME}.app/Contents/Resources/bin/go2rtc" 2>/dev/null || true
}
trap cleanup EXIT

if ! command -v go2rtc >/dev/null 2>&1 && command -v devenv >/dev/null 2>&1; then
  GO2RTC_PATH="$(devenv shell -- command -v go2rtc 2>/dev/null | grep -E '^/.*/go2rtc$' | tail -n 1 || true)"
  if [[ -n "$GO2RTC_PATH" ]]; then
    export PATH="$(dirname "$GO2RTC_PATH"):$PATH"
  fi
fi

if ! command -v go2rtc >/dev/null 2>&1; then
  fail "go2rtc not found on PATH; run from devenv shell"
fi

mkdir -p "$OUT_DIR"
cd "$ROOT_DIR"

log "==> Killing existing ${APP_NAME}"
pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
pkill -f "${APP_NAME}.app/Contents/Resources/bin/go2rtc" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

log "==> swift test"
swift test -q

log "==> package app"
ARCHES="$(uname -m)" APP_NAME="$APP_NAME" BUNDLE_ID="com.cambar" MENU_BAR_APP=1 \
  "$ROOT_DIR/Scripts/package_app.sh" release

log "==> launch app with ${POPOVER_CYCLES} popover cycles"
open -n \
  --stdout "$OUT_DIR/app.log" \
  --stderr "$OUT_DIR/app.log" \
  --env "CAMBAR_DEBUG_POPOVER_CYCLES=$POPOVER_CYCLES" \
  --env "CAMBAR_DEBUG_POPOVER_START_DELAY_SECONDS=$POPOVER_START_DELAY_SECONDS" \
  --env "CAMBAR_DEBUG_POPOVER_VISIBLE_SECONDS=$POPOVER_VISIBLE_SECONDS" \
  --env "CAMBAR_DIAGNOSTICS=1" \
  "$APP_BUNDLE"

for _ in {1..40}; do
  APP_PID="$(pgrep -f "$APP_PROCESS_PATTERN" | head -n 1 || true)"
  if [[ -n "$APP_PID" ]]; then
    break
  fi
  sleep 0.25
done
if [[ -z "$APP_PID" ]]; then
  fail "${APP_NAME} did not launch; see $OUT_DIR/app.log"
fi

for _ in {1..80}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    fail "${APP_NAME} exited early; see $OUT_DIR/app.log"
  fi
  if [[ -f "$TELEMETRY" ]] \
    && [[ "$(grep -c '"event":"debug_popover_cycle"' "$TELEMETRY" || true)" -ge "$POPOVER_CYCLES" ]] \
    && [[ "$(grep -c '"event":"webview_snapshot_sample"' "$TELEMETRY" || true)" -ge "$POPOVER_CYCLES" ]]; then
    break
  fi
  sleep 0.25
done

if [[ ! -f "$TELEMETRY" ]] \
  || [[ "$(grep -c '"event":"debug_popover_cycle"' "$TELEMETRY" || true)" -lt "$POPOVER_CYCLES" ]] \
  || [[ "$(grep -c '"event":"webview_snapshot_sample"' "$TELEMETRY" || true)" -lt "$POPOVER_CYCLES" ]]; then
  fail "popover did not reach a rendered WebView snapshot; see $OUT_DIR/app.log"
fi

set +e
SNAPSHOT_ANALYSIS="$(
swift -e '
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: analyze <telemetry path> <expected snapshots>\n", stderr)
    exit(1)
}
let text = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? ""
let expected = Int(CommandLine.arguments[2]) ?? 1
let details = text.split(separator: "\n").compactMap { line -> String? in
    guard let data = String(line).data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["event"] as? String) == "webview_snapshot_sample" else {
        return nil
    }
    return json["detail"] as? String
}
let selected = Array(details.suffix(expected))
guard selected.count == expected else {
    fputs("missing webview_snapshot_sample: expected \(expected), got \(details.count)\n", stderr)
    exit(1)
}
func value(_ key: String, in detail: String) -> Double? {
    guard let range = detail.range(of: "\(key)=([0-9.]+)", options: .regularExpression) else {
        return nil
    }
    return Double(detail[range].split(separator: "=").last ?? "")
}
var failed = false
for detail in selected {
    guard let white = value("white", in: detail),
          let dark = value("dark", in: detail),
          let color = value("color", in: detail) else {
        fputs("could not parse snapshot ratios: \(detail)\n", stderr)
        exit(1)
    }
    print(detail)
    if white > 0.85 || dark > 0.85 || color < 0.05 {
        failed = true
    }
}
if failed {
    exit(2)
}
' "$TELEMETRY" "$POPOVER_CYCLES" 2>&1
)"
SNAPSHOT_STATUS=$?
set -e
printf '%s\n' "$SNAPSHOT_ANALYSIS" | tee "$OUT_DIR/webview-snapshot-analysis.txt"

swift -e '
import Foundation

let text = (try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)) ?? ""
let expected = Int(CommandLine.arguments[2]) ?? 1
let timings = text.split(separator: "\n").compactMap { line -> Int? in
    guard let data = String(line).data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (json["event"] as? String) == "live_view",
          let elapsed = json["elapsed_ms"] as? Int else {
        return nil
    }
    return elapsed
}
let selected = Array(timings.suffix(expected))
guard selected.count == expected else {
    fputs("missing live_view timings: expected \(expected), got \(timings.count)\n", stderr)
    exit(1)
}
for elapsed in selected {
    print("live_view elapsed_ms=\(elapsed)")
}
if selected.contains(where: { $0 >= 500 }) {
    exit(2)
}
' "$TELEMETRY" "$POPOVER_CYCLES" | tee "$OUT_DIR/fresh-timing.txt"

collect_artifacts

if [[ "$SNAPSHOT_STATUS" -ne 0 ]]; then
  fail "popover WebView snapshot is still blank; artifacts in $OUT_DIR"
fi

log "OK: popover WebView snapshot has live pixels. Artifacts: $OUT_DIR"
