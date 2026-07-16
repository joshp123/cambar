---
written_by: ai
---

# CamBar Agent Guide

Purpose: one-stop shop for agents to develop + debug CamBar fast.

## North Star
- CamBar is an ultraminimal, fast, menu-bar-only camera viewer.
- The feed is the product: opening the menu bar app should show current live video fast, with no stale-frame catch-up weirdness.
- Default answer to new UI/features is no unless they make live video faster, more reliable, or simpler.
- Use the Build macOS Apps plugin/skills for macOS lifecycle, SwiftUI/AppKit, menu-bar UI, packaging, signing, and debugging work.

## What CamBar is
- Tiny macOS menubar RTSP viewer.
- Pipeline: RTSP camera → IPCamKit → hardware VideoToolbox decode → native video surface.
- Stream policy:
  - the main stream `/Streaming/Channels/101` is warmed at launch/login
  - retain only the newest decoded frame; never accumulate a playback queue
  - normal playback must not use go2rtc, WebKit, ffmpeg, HLS files or AVPlayer
  - old fallback playback paths should be deleted, not preserved

## 60-second bootstrap
```bash
cd /Users/josh/code/macos-cam-app

devenv shell   # if toolchain not already present
./Scripts/compile_and_run.sh --test
./Scripts/deploy_app.sh   # explicit install; never launches or kills CamBar
./Scripts/presentation_canary.sh   # explicit background launch; kills on unsolicited UI
```

## Runtime inputs (source of truth)
RTSP resolution order:
1. `CAMBAR_RTSP_URL`
2. `~/.config/camsnap/config.yaml`

## Architecture map (read this before edits)
- `Sources/CamBar/main.swift` + `AppDelegate.swift`
  - app lifecycle, menubar app wiring
- `Sources/CamBar/ContentView.swift`
  - minimal popover UI
- `Sources/CamBar/CameraStreamController.swift` + `VideoToolboxDecoder.swift`
  - one app-lifetime RTSP session, hardware H.264 decode, latest-frame cache and reconnect supervision
- `Sources/CamBar/CameraPlaybackController.swift` + `CameraVideoView.swift`
  - fixed native menu and popout surfaces; the surfaces are never reparented and never own the stream
- `Sources/CamBarCore/PopoverPresentationState.swift`
  - fail-closed popover intent/callback reducer
- `Sources/CamBar/CameraWindowController.swift`
  - large/popout window behavior
- `Sources/CamBarCore/StreamSourceResolver.swift`
  - URL/config parsing and credential redaction
- `Sources/CamBarCore/NativeStreamPolicy.swift`
  - cached-frame freshness, post-click frame acceptance, reconnect delay and AVCC packetisation
- `Sources/CamBarCore/DirectStreamTelemetry.swift`
  - local JSONL timing log
- `Vendor/IPCamKit`
  - pinned IPCamKit 0.3.1 source plus CamBar's immediate socket-abort extension
- `Tests/CamBarTests/CamBarTests.swift`
  - resolver + behavior tests

## Change discipline
- Small surgical edits.
- Fix root cause first; avoid workaround layering.
- Never commit camera creds or unmasked RTSP URLs.
- Re-run tests after behavior changes.

## Fast failure classification
Run in order:
```bash
tailscale status
tailscale ping -c 1 192.168.1.249
nc -zv 192.168.1.249 554
./Scripts/verify_release_safety.sh
```

Interpretation:
- ping fails -> routing/ACL/subnet-router problem
- ping ok + port fails -> camera/RTSP path/firewall problem
- ping ok + port ok + app fails -> CamBar RTSP/decode/presentation logic

## Travel/remote notes (Tailscale)
- Subnet router != exit node.
- CamBar needs reachability to camera `192.168.1.249:554`; exit node not required.
- Known current topology: `josh-nas` advertises `192.168.1.0/24`.
- Helpful checks:
```bash
tailscale debug prefs | jq '{WantRunning,RouteAll,ExitNodeID,ExitNodeAllowLANAccess}'
route -n get 192.168.1.249 | rg 'interface|gateway|flags'
```

## Done criteria before handoff
- `./Scripts/verify_release_safety.sh` passes.
- The signed bundle is staged and installed without launching it automatically.
- `./Scripts/presentation_canary.sh` reports no unsolicited presentation.
- App launches and plays stream in:
  - menu popover
  - popout window
- No secret leakage in diffs/log statements.
- Summary includes root cause, fix, and how it was verified.

## One-shot onboarding prompt for agents
```text
Onboard to CamBar from AGENTS.md only.
1) Summarize architecture and runtime flow with exact file paths.
2) Run tests and report status.
3) Identify highest-risk areas for regressions.
4) Propose minimal-safe plan before editing.
No broad refactors.
```
