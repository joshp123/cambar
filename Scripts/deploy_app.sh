#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=CamBar
BUILT_APP="$ROOT/.build/package/$APP_NAME.app"
APP="$HOME/Applications/$APP_NAME.app"
NEW_APP="$HOME/Applications/.$APP_NAME.app.new"
PREVIOUS_APP="$HOME/Applications/.$APP_NAME.app.previous"
ROLLBACK_DIR="$HOME/Library/Caches/CamBar/rollback"
ROLLBACK_ZIP="$ROLLBACK_DIR/$APP_NAME-previous.zip"

if [[ $# -gt 0 ]]; then
  echo "Usage: $(basename "$0")" >&2
  exit 2
fi

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  echo "ERROR: refusing to deploy a dirty working tree." >&2
  exit 1
fi
if [[ ! -d "$BUILT_APP" ]]; then
  echo "ERROR: missing staged app; run Scripts/package_app.sh first." >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :GitCommit' "$BUILT_APP/Contents/Info.plist")" != "$(git rev-parse --short HEAD)" ]]; then
  echo "ERROR: staged app does not match HEAD; rebuild before deploying." >&2
  exit 1
fi
if pgrep -f "$APP/Contents/MacOS/$APP_NAME" >/dev/null; then
  echo "ERROR: quit CamBar before deployment; this script will not kill a live app." >&2
  exit 1
fi

"$ROOT/Scripts/verify_release_safety.sh"

if [[ -e "$APP" ]]; then
  CURRENT_REQUIREMENT=$(codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => //p')
  STAGED_REQUIREMENT=$(codesign -dr - "$BUILT_APP" 2>&1 | sed -n 's/^designated => //p')
  if [[ -z "$CURRENT_REQUIREMENT" || -z "$STAGED_REQUIREMENT" ]]; then
    echo "ERROR: could not read app signing requirement." >&2
    exit 1
  fi
  if [[ "$CURRENT_REQUIREMENT" != "$STAGED_REQUIREMENT" ]]; then
    echo "ERROR: app signing requirement changed; refusing deployment." >&2
    exit 1
  fi
fi

mkdir -p "$HOME/Applications" "$ROLLBACK_DIR"
if [[ -e "$NEW_APP" ]]; then
  trash "$NEW_APP"
fi
if [[ -e "$PREVIOUS_APP" ]]; then
  trash "$PREVIOUS_APP"
fi
ditto "$BUILT_APP" "$NEW_APP"
codesign --verify --deep --strict "$NEW_APP"

had_previous=0
if [[ -e "$APP" ]]; then
  had_previous=1
  if [[ -e "$ROLLBACK_ZIP" ]]; then
    trash "$ROLLBACK_ZIP"
  fi
  ditto -c -k --keepParent "$APP" "$ROLLBACK_ZIP"
  mv "$APP" "$PREVIOUS_APP"
fi

rollback() {
  local exit_code=$?
  trap - EXIT
  set +e
  local rollback_failed=0
  if [[ -e "$APP" ]]; then
    trash "$APP" || rollback_failed=1
  fi
  if [[ "$had_previous" == "1" && -e "$PREVIOUS_APP" ]]; then
    mv "$PREVIOUS_APP" "$APP" || rollback_failed=1
  fi
  if [[ "$rollback_failed" != "0" ]]; then
    echo "ERROR: deployment failed and automatic rollback was incomplete." >&2
  fi
  exit "$exit_code"
}
trap rollback EXIT

mv "$NEW_APP" "$APP"
codesign --verify --deep --strict "$APP"
trap - EXIT
if [[ -e "$PREVIOUS_APP" ]]; then
  trash "$PREVIOUS_APP"
fi
echo "Installed $APP"
echo "Not launched. Run Scripts/presentation_canary.sh as a separate explicit launch check."
