# CamBar Agent Guide

Purpose: one-stop shop for agents to develop + debug CamBar fast.

## North Star
- CamBar is an ultraminimal, fast, menu-bar-only camera viewer.
- The feed is the product: opening the menu bar app should show current live video fast, with no stale-frame catch-up weirdness.
- Default answer to new UI/features is no unless they make live video faster, more reliable, or simpler.
- Use the Build macOS Apps plugin/skills for macOS lifecycle, SwiftUI/AppKit, menu-bar UI, packaging, signing, and debugging work.

## What CamBar is
- Tiny macOS menubar RTSP viewer.
- Pipeline: RTSP camera -> bundled go2rtc -> direct WebKit video surface.
- Stream policy:
  - the main stream `/Streaming/Channels/101` is warmed at launch/login
  - normal playback must not use ffmpeg, HLS files, or AVPlayer
  - old fallback playback paths should be deleted, not preserved

## 60-second bootstrap
```bash
cd /Users/josh/code/macos-cam-app

devenv shell   # if toolchain not already present
./Scripts/compile_and_run.sh
./Scripts/compile_and_run.sh --test
```

## Runtime inputs (source of truth)
RTSP resolution order:
1. `CAMBAR_RTSP_URL`
2. `~/.config/camsnap/config.yaml`

Debug env:
- `CAMBAR_OPEN_WINDOW=1` -> opens the popout after relay/view warmup for visual testing

## Architecture map (read this before edits)
- `Sources/CamBar/main.swift` + `AppDelegate.swift`
  - app lifecycle, menubar app wiring
- `Sources/CamBar/ContentView.swift`
  - minimal popover UI
- `Sources/CamBar/Go2RTCVideoView.swift`
  - direct live video WebKit surface and prewarmed menu/window views
- `Sources/CamBar/CameraWindowController.swift`
  - large/popout window behavior
- `Sources/CamBar/Go2RTCRelayController.swift`
  - bundled go2rtc lifecycle and localhost config
- `Sources/CamBarCore/StreamSourceResolver.swift`
  - URL/config parsing and executable path resolution
- `Sources/CamBarCore/DirectStreamTelemetry.swift`
  - local JSONL timing log
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
./Scripts/compile_and_run.sh --test
```

Interpretation:
- ping fails -> routing/ACL/subnet-router problem
- ping ok + port fails -> camera/RTSP path/firewall problem
- ping ok + port ok + app fails -> CamBar/go2rtc/WebKit app logic

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
- `./Scripts/compile_and_run.sh --test` passes.
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
