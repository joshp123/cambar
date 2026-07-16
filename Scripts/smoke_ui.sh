#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/Scripts/Support/CamBarSmokeHarness.swift"
BUILD_DIR="$ROOT/.build/support"
HARNESS="$BUILD_DIR/cambar-smoke-ui"
APP="$HOME/Applications/CamBar.app"
EXECUTABLE="$APP/Contents/MacOS/CamBar"
HELPER="$APP/Contents/Resources/bin/go2rtc"
PID_FILE="$BUILD_DIR/smoke-ui-owned.pids"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "$APP" ]] || fail "CamBar is not installed at $APP"
[[ -x "$EXECUTABLE" ]] || fail "CamBar executable is missing"
[[ -x "$HELPER" ]] || fail "CamBar's bundled go2rtc is missing"
codesign --verify --deep --strict "$APP" \
  || fail "installed CamBar failed code-signature verification"
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]] \
  || fail "working tree is dirty"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "$APP/Contents/Info.plist")" == "$(git -C "$ROOT" rev-parse --short HEAD)" ]] \
  || fail "installed CamBar does not match HEAD"
if pgrep -f "$EXECUTABLE" >/dev/null; then
  fail "CamBar is already running; refusing to disturb it"
fi
if pgrep -f "$HELPER" >/dev/null; then
  fail "CamBar's bundled go2rtc is already running; refusing to disturb it"
fi

unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS
export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache"
export SWIFT_MODULECACHE_PATH="$BUILD_DIR/module-cache"
mkdir -p "$BUILD_DIR" "$CLANG_MODULE_CACHE_PATH"
/usr/bin/swiftc "$SOURCE" -o "$HARNESS"
: > "$PID_FILE"

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM HUP
  local app_pid=""
  local recorded_app_pid=""
  local -a owned_pids=()
  if [[ -f "$PID_FILE" ]]; then
    while read -r role pid parent_pid; do
      [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
      if [[ "$role" == "app" ]]; then
        recorded_app_pid=$pid
      fi
      local command
      command=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
      if [[ "$role" == "app" && ( "$command" == "$EXECUTABLE" || "$command" == "$EXECUTABLE "* ) ]]; then
        app_pid=$pid
        owned_pids+=("$pid")
      elif [[ "$role" == "helper" && "$parent_pid" == "$recorded_app_pid" \
        && ( "$command" == "$HELPER" || "$command" == "$HELPER "* ) ]]; then
        owned_pids+=("$pid")
      fi
    done < "$PID_FILE"
  fi
  if [[ -n "$app_pid" ]]; then
    /bin/kill -TERM "$app_pid" >/dev/null 2>&1 || true
    sleep 0.5
  fi
  local pid
  for pid in "${owned_pids[@]}"; do
    /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  sleep 0.2
  for pid in "${owned_pids[@]}"; do
    /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

CAMBAR_SMOKE_PID_FILE="$PID_FILE" "$HARNESS" "$@"
