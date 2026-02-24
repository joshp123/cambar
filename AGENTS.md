# CamBar Agent Guide

Purpose: one-stop shop for agents to develop + debug CamBar fast.

## What CamBar is
- Tiny macOS menubar RTSP viewer.
- Pipeline: RTSP -> ffmpeg -> local HLS -> AVPlayer.
- Dual stream policy:
  - small/popover: preview stream `/Streaming/Channels/102` when derivable
  - large/popout: main stream `/Streaming/Channels/101`

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
- `CAMBAR_DEBUG_HTTP=1` -> HLS request logging

## Architecture map (read this before edits)
- `Sources/CamBar/main.swift` + `AppDelegate.swift`
  - app lifecycle, menubar app wiring
- `Sources/CamBar/ContentView.swift`
  - popover UI + primary app state
- `Sources/CamBar/LiveVideoView.swift`
  - AVPlayer host view
- `Sources/CamBar/CameraWindowController.swift`
  - large/popout window behavior
- `Sources/CamBar/CameraFrameProvider.swift`
  - ffmpeg lifecycle + stream session orchestration
- `Sources/CamBar/HLSServer.swift`
  - local HLS file/serve behavior
- `Sources/CamBar/StreamStatusView.swift`
  - shared status UI component
- `Sources/CamBarCore/StreamSourceResolver.swift`
  - URL/config parsing, stream derivation (`101` <-> `102`), path resolution
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
- ping ok + port ok + app fails -> CamBar/ffmpeg/HLS/app logic

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
  - small mode (preview/102 when available)
  - large mode (main/101)
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
