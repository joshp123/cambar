#!/usr/bin/env bash
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=${APP_NAME:-CamBar}
BUNDLE_ID=${BUNDLE_ID:-com.cambar}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-14.0}
MENU_BAR_APP=${MENU_BAR_APP:-1}
SIGNING_MODE=${SIGNING_MODE:-auto}
APP_IDENTITY=${APP_IDENTITY:-}

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
  BUILD_NUMBER=${BUILD_NUMBER:-1}
fi

ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  ARCH_LIST=("$HOST_ARCH")
fi
if [[ ${#ARCH_LIST[@]} -ne 1 ]]; then
  echo "ERROR: CamBar packaging supports one architecture at a time." >&2
  exit 1
fi

GO2RTC_SOURCE=$(command -v go2rtc || true)
if [[ ! -x "$GO2RTC_SOURCE" ]]; then
  echo "ERROR: go2rtc not found on PATH. Enter devenv shell or run: nix shell nixpkgs#go2rtc -c Scripts/package_app.sh" >&2
  exit 1
fi
GO2RTC_ARCHES=$(lipo -archs "$GO2RTC_SOURCE")
if [[ "$GO2RTC_ARCHES" != *"${ARCH_LIST[0]}"* ]]; then
  echo "ERROR: go2rtc does not contain required architecture ${ARCH_LIST[0]} (have: ${GO2RTC_ARCHES})." >&2
  exit 1
fi

BUILD_PRODUCT_DIRS=()
STAGED_PRODUCT_ROOT="$ROOT/.build/cambar-package/$CONF"
for ARCH in "${ARCH_LIST[@]}"; do
  swift build -c "$CONF" --arch "$ARCH"
  PRODUCT_DIR=$(swift build -c "$CONF" --arch "$ARCH" --show-bin-path)
  PRODUCT="$PRODUCT_DIR/$APP_NAME"
  if [[ ! -x "$PRODUCT" ]]; then
    echo "ERROR: Missing ${APP_NAME} build for ${ARCH} at ${PRODUCT}" >&2
    exit 1
  fi
  STAGED_ARCH_DIR="$STAGED_PRODUCT_ROOT/$ARCH"
  mkdir -p "$STAGED_ARCH_DIR"
  cp "$PRODUCT" "$STAGED_ARCH_DIR/$APP_NAME"
  BUILD_PRODUCT_DIRS+=("$PRODUCT_DIR")
done

APP="$ROOT/${APP_NAME}.app"
if [[ -e "$APP" ]]; then
  trash "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# Convert Icon.icon to Icon.icns if present (requires iconutil).
ICON_SOURCE="$ROOT/Icon.icon"
ICON_TARGET="$ROOT/Icon.icns"
if [[ -f "$ICON_SOURCE" ]]; then
  iconutil --convert icns --output "$ICON_TARGET" "$ICON_SOURCE"
fi

LSUI_VALUE="false"
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE="true"
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
    <key>NSLocalNetworkUsageDescription</key><string>CamBar needs local network access to reach your RTSP camera.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
        <key>NSAllowsArbitraryLoadsInMedia</key><true/>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

build_product_path() {
  local name="$1"
  local arch="$2"
  echo "$STAGED_PRODUCT_ROOT/$arch/$name"
}

verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  local actual_count expected_count
  actual_count=$(wc -w <<<"$actual" | tr -d ' ')
  expected_count=${#expected[@]}
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    echo "ERROR: $binary arch mismatch (expected: ${expected[*]}, actual: ${actual})" >&2
    exit 1
  fi
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

install_binary "$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Bundle app resources (if any).
APP_RESOURCES_DIR="$ROOT/Sources/$APP_NAME/Resources"
if [[ -d "$APP_RESOURCES_DIR" ]]; then
  cp -R "$APP_RESOURCES_DIR/." "$APP/Contents/Resources/"
fi

# SwiftPM resource bundles are emitted next to the built binary.
PREFERRED_BUILD_DIR="${BUILD_PRODUCT_DIRS[0]}"
shopt -s nullglob
SWIFTPM_BUNDLES=("${PREFERRED_BUILD_DIR}/"*.bundle)
shopt -u nullglob
if [[ ${#SWIFTPM_BUNDLES[@]} -gt 0 ]]; then
  for bundle in "${SWIFTPM_BUNDLES[@]}"; do
    cp -R "$bundle" "$APP/Contents/Resources/"
  done
fi

# Embed frameworks if any exist in the build folder.
FRAMEWORK_DIRS=("${BUILD_PRODUCT_DIRS[0]}")
for dir in "${FRAMEWORK_DIRS[@]}"; do
  if compgen -G "${dir}/*.framework" >/dev/null; then
    cp -R "${dir}/"*.framework "$APP/Contents/Frameworks/"
    chmod -R a+rX "$APP/Contents/Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"
    break
  fi
done

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

# Bundle required helper binaries. go2rtc is part of the app architecture; do not
# ship an app that falls back to the old slow playback path because packaging ran
# outside the repo's devenv/Nix shell.
BUNDLE_BIN_DIR="$APP/Contents/Resources/bin"
mkdir -p "$BUNDLE_BIN_DIR"
cp "$GO2RTC_SOURCE" "$BUNDLE_BIN_DIR/go2rtc"
chmod +x "$BUNDLE_BIN_DIR/go2rtc"
verify_binary_arches "$BUNDLE_BIN_DIR/go2rtc" "${ARCH_LIST[@]}"

# Ensure contents are writable before stripping attributes and signing.
chmod -R u+w "$APP"

# Strip extended attributes to prevent AppleDouble files that break code sealing.
xattr -cr "$APP"
while IFS= read -r -d '' APPLEDOUBLE_FILE; do
  trash "$APPLEDOUBLE_FILE"
done < <(find "$APP" -name '._*' -print0)

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
DEFAULT_ENTITLEMENTS="$ENTITLEMENTS_DIR/${APP_NAME}.entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

APP_ENTITLEMENTS=${APP_ENTITLEMENTS:-$DEFAULT_ENTITLEMENTS}
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  cat > "$APP_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Add entitlements here if needed. -->
</dict>
</plist>
PLIST
fi

if [[ "$SIGNING_MODE" == "auto" && -z "$APP_IDENTITY" ]]; then
  APP_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/^[[:space:]]*[0-9]+\)/ { print $2; exit }')
  if [[ -z "$APP_IDENTITY" ]]; then
    SIGNING_MODE=adhoc
  fi
fi

if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
else
  CODESIGN_ARGS=(--force --options runtime --sign "$APP_IDENTITY")
fi

# Sign embedded frameworks and their nested binaries before the app bundle.
sign_frameworks() {
  local fw
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    if [[ ! -d "$fw" ]]; then
      continue
    fi
    while IFS= read -r -d '' bin; do
      codesign "${CODESIGN_ARGS[@]}" "$bin"
    done < <(find "$fw" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$fw"
  done
}
sign_frameworks

for HELPER in "$APP/Contents/Resources/bin/"*; do
  if [[ -f "$HELPER" && -x "$HELPER" ]]; then
    codesign "${CODESIGN_ARGS[@]}" "$HELPER"
  fi
done

codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"
