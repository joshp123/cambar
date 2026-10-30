#!/usr/bin/env bash
set -euo pipefail

unset SDKROOT DEVELOPER_DIR NIX_CFLAGS_COMPILE NIX_LDFLAGS
export DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=CamBar
BUNDLE_ID=com.cambar
ARCH=${ARCHES:-$(uname -m)}
APP_IDENTITY=${APP_IDENTITY:-}
EXPECTED_TEAM_ID=7M8BR7R488
source "$ROOT/version.env"
BUILD_NUMBER=$(git rev-list --count HEAD)

if [[ "$ARCH" == *" "* ]]; then
  echo "ERROR: CamBar packaging supports one architecture at a time." >&2
  exit 1
fi

swift build -c "$CONF" --arch "$ARCH"
PRODUCT_DIR=$(swift build -c "$CONF" --arch "$ARCH" --show-bin-path)
PRODUCT="$PRODUCT_DIR/$APP_NAME"
if [[ ! -x "$PRODUCT" ]]; then
  echo "ERROR: Missing $APP_NAME build at $PRODUCT" >&2
  exit 1
fi
if [[ "$(lipo -archs "$PRODUCT")" != "$ARCH" ]]; then
  echo "ERROR: $APP_NAME build architecture does not match $ARCH." >&2
  exit 1
fi

STAGING_ROOT="$ROOT/.build/package"
STAGED_APP="$STAGING_ROOT/$APP_NAME.app-staging"
BUILT_APP="$STAGING_ROOT/$APP_NAME.app"
APP="$HOME/Applications/$APP_NAME.app"
EXISTING_TEAM_ID=""
if [[ -e "$APP" ]]; then
  EXISTING_TEAM_ID=$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2; exit }')
fi
if [[ -e "$STAGED_APP" ]]; then
  trash "$STAGED_APP"
fi
mkdir -p "$STAGED_APP/Contents/MacOS"
cp "$PRODUCT" "$STAGED_APP/Contents/MacOS/$APP_NAME"
chmod -R u+w "$STAGED_APP"
chmod +x "$STAGED_APP/Contents/MacOS/$APP_NAME"

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  GIT_COMMIT="${GIT_COMMIT}-dirty"
fi
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CamBar</string>
    <key>CFBundleDisplayName</key><string>CamBar</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>CamBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
    <key>NSLocalNetworkUsageDescription</key><string>CamBar needs local network access to reach your RTSP camera.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

xattr -cr "$STAGED_APP"
if [[ -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ { print $2; exit }')
fi
if [[ -z "$APP_IDENTITY" ]]; then
  echo "ERROR: Apple Development signing identity not found; refusing an unstable ad-hoc build." >&2
  exit 1
fi
SIGN_ARGS=(--force --options runtime --sign "$APP_IDENTITY")
codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
STAGED_TEAM_ID=$(codesign -dv --verbose=4 "$STAGED_APP" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2; exit }')
if [[ "$STAGED_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "ERROR: signing team $STAGED_TEAM_ID does not match expected team $EXPECTED_TEAM_ID." >&2
  exit 1
fi
if [[ -n "$EXISTING_TEAM_ID" && "$STAGED_TEAM_ID" != "$EXISTING_TEAM_ID" ]]; then
  echo "ERROR: signing team changed from $EXISTING_TEAM_ID to $STAGED_TEAM_ID; preserving Local Network permission identity." >&2
  exit 1
fi

if [[ -e "$BUILT_APP" ]]; then
  trash "$BUILT_APP"
fi
mv "$STAGED_APP" "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"
echo "Built $BUILT_APP"
