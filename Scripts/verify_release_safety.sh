#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

if rg -n 'NSStatusItemExpandedInterface|CAMBAR_OPEN_(WINDOW|POPOVER)' Sources; then
  fail "release source contains expanded-interface or autonomous-open hooks"
fi

if rg -n 'activate\(ignoringOtherApps:' Sources/CamBar/AppDelegate.swift; then
  fail "release source contains forced app activation"
fi
ACTIVATIONS=$(rg -n 'NSApp\.activate\(\)' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$ACTIVATIONS" == "1" ]] || fail "release source must contain exactly one cooperative popout activation"
ACTIVATION_YIELDS=$(rg -n 'NSApp\.yieldActivation\(to:' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$ACTIVATION_YIELDS" == "1" ]] || fail "release source must contain exactly one cooperative activation yield"
OPEN_WINDOW_CALLS=$(rg -n 'openWindow\(\)' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$OPEN_WINDOW_CALLS" == "2" ]] || fail "openWindow must only be defined and called by the expand-button action"
POPOVER_ENTRY_POINTS=$(rg -n 'presentPopoverFromStatusItem\(\)' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$POPOVER_ENTRY_POINTS" == "2" ]] || fail "popover presentation must only be defined and called by the click reducer"
POPOVER_SHOWS=$(rg -n 'popover\.show\(' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$POPOVER_SHOWS" == "1" ]] || fail "release source must contain one popover presentation call"
WINDOW_FRONTS=$(rg -n 'makeKeyAndOrderFront\(' Sources/CamBar | wc -l | tr -d ' ')
[[ "$WINDOW_FRONTS" == "1" ]] || fail "release source must contain one explicit window-front call"

if rg -n 'import WebKit|WKWebView|go2rtc|Go2RTC|ffmpeg|NWListener|AVPlayer' Sources; then
  fail "release source contains an obsolete playback pipeline"
fi

RTSP_SESSIONS=$(rg -n 'RTSPClientSession\(' Sources/CamBar | wc -l | tr -d ' ')
[[ "$RTSP_SESSIONS" == "1" ]] || fail "release source must own exactly one RTSP session construction site"
DECODER_SESSIONS=$(rg -n 'VTDecompressionSessionCreate\(' Sources/CamBar | wc -l | tr -d ' ')
[[ "$DECODER_SESSIONS" == "1" ]] || fail "release source must own exactly one hardware decoder construction site"
rg -q 'public func abort\(\) async' Vendor/IPCamKit/Sources/IPCamKit/Client/RTSPSession.swift \
  || fail "vendored RTSP client is missing immediate fault-path abort"
rg -q 'await activeSession\?\.abort\(\)' Sources/CamBar/CameraStreamController.swift \
  || fail "stream recovery is not using immediate RTSP abort"
[[ ! -d .build/package/CamBar.app/Contents/Resources/bin ]] \
  || fail "staged app contains an obsolete helper directory"

swift test -q
echo "Release source safety checks passed."
