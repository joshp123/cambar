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

ACTIVATIONS=$(rg -n 'NSApp\.activate\(ignoringOtherApps: true\)' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$ACTIVATIONS" == "1" ]] || fail "release source must contain exactly one explicit popout activation"
OPEN_WINDOW_CALLS=$(rg -n 'openWindow\(\)' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$OPEN_WINDOW_CALLS" == "2" ]] || fail "openWindow must only be defined and called by the expand-button action"
POPOVER_ENTRY_POINTS=$(rg -n 'presentPopoverFromStatusItem\(\)' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$POPOVER_ENTRY_POINTS" == "2" ]] || fail "popover presentation must only be defined and called by the click reducer"
POPOVER_SHOWS=$(rg -n 'popover\.show\(' Sources/CamBar/AppDelegate.swift | wc -l | tr -d ' ')
[[ "$POPOVER_SHOWS" == "1" ]] || fail "release source must contain one popover presentation call"
WINDOW_FRONTS=$(rg -n 'makeKeyAndOrderFront\(' Sources/CamBar | wc -l | tr -d ' ')
[[ "$WINDOW_FRONTS" == "1" ]] || fail "release source must contain one explicit window-front call"

if rg -n 'parkingWindow|parkingView|alphaValue\s*=\s*0\.0?1' Sources; then
  fail "release source contains an offscreen WebKit parking path"
fi

swift test -q
echo "Release source safety checks passed."
