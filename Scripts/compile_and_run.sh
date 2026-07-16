#!/usr/bin/env bash
# Compatibility wrapper: test and stage a signed bundle without installing or launching it.
set -euo pipefail

unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS
export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

command -v go2rtc >/dev/null 2>&1 || fail "go2rtc not found on PATH; enter the devenv shell."

if [[ "${RUN_TESTS}" == "1" ]]; then
  log "==> swift test"
  swift test -q
fi

log "==> stage signed app"
"${ROOT_DIR}/Scripts/package_app.sh" release
log "OK: staged .build/package/CamBar.app; nothing was installed or launched."
