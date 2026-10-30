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
cd /Users/josh/code/cambar

devenv shell   # if toolchain not already present
swift test
swift build && .build/debug/CamBar --probe 10   # headless: real RTSP + hardware decode, JSON summary
./Scripts/deploy_app.sh   # commit first; tests, installs, restarts in background, checks the log
```

## Testing and debugging without getting in Josh's way
Josh uses this Mac while agents work. Never open the popover, take screenshots
or drive the UI unless the change is to presentation code and he has agreed.
Look at raw evidence and reason from it; do not build bespoke assertions.

1. `swift test` for the reducers, parsers and frame policy.
2. `CamBar --probe [seconds]` for the stream pipeline: the same
   `CameraStreamController` and VideoToolbox decoder as the app, with no UI and
   no effect on the running app. stderr is the telemetry; stdout is one JSON
   line (`result`: `live`, `stalled`, `no_video` or `no_camera_configured`;
   `first_frame_ms`, `fps`, size, `retries`). It saves the last frame to
   `last_frame_png` with its local decode time in `last_frame_decoded_at`.
   Open the PNG: the camera prints its clock top left, so the difference is
   the real end-to-end latency, and you can see black, garbled or frozen video.
   Set `CAMBAR_RTSP_URL` to probe another stream (`/Streaming/Channels/102` is
   the substream). Use `~/Applications/CamBar.app/Contents/MacOS/CamBar --probe`
   to test the installed build.
3. The running app's log, `~/Library/Caches/CamBar/direct/direct-stream-events.jsonl`
   (also in `log show --predicate 'subsystem == "com.cambar"'`). Filter by the
   newest `launch` event's `session_id`. What to read:
   - `network_changed`: interfaces up (`utun*` is Tailscale).
   - `rtsp diagnostic "TCP connected <local>(me)-><camera>"`: which address
     reached the camera. A `100.x` local address means Tailscale.
   - `session_stopped`: the real failure, with `[interface=… local=…]` for
     connection failures, plus duration, frame and byte counts and
     `last_packet_age_ms`. Framing errors include the next raw bytes.
   - `frame_heartbeat` every 5 s: `encoded_kbps` received and frame counts.
     The main stream needs about 5 Mbit/s; lower means the link is the limit.
   - `live_view.elapsed_ms`: click-to-live time.
4. `Scripts/smoke_ui.sh` drives the real popover on screen. Last resort only.

## Runtime inputs (source of truth)
RTSP resolution order:
1. `CAMBAR_RTSP_URL`
2. `~/.config/camsnap/config.yaml`

## Architecture map (read this before edits)
- `Sources/CamBar/main.swift` + `AppDelegate.swift`
  - app lifecycle, menubar app wiring
- `Sources/CamBar/HeadlessStreamProbe.swift`
  - `--probe` mode for agents and diagnosis
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
route -n get 192.168.1.249 | rg interface
.build/debug/CamBar --probe 10
```

Interpretation:
- away from home, the route must use a `utun` interface. If it says `en0`
  and `nc` reports "Host is down", the local network also uses
  192.168.1.0/24 and is winning. `josh-nas` advertises `192.168.1.249/32`
  alongside the /24 for exactly this; check that route is still advertised
  and approved
- ping fails -> routing/ACL/subnet-router problem
- ping ok + port fails -> camera/RTSP path/firewall problem
- ping ok + port ok + app fails -> CamBar RTSP/decode/presentation logic

## Travel/remote notes (Tailscale)
- Subnet router != exit node.
- CamBar needs reachability to camera `192.168.1.249:554`; exit node not required.
- Known current topology: `josh-nas` advertises `192.168.1.0/24` and the
  camera's `192.168.1.249/32`. The /32 is more specific than any hotel or
  Airbnb network that also uses 192.168.1.0/24, so macOS sends camera traffic
  through Tailscale everywhere, including at home (via the NAS).
- Away from home the warm stream carries the camera bitrate over Tailscale
  for as long as CamBar runs.
- Helpful checks:
```bash
tailscale debug prefs | jq '{WantRunning,RouteAll,ExitNodeID,ExitNodeAllowLANAccess}'
route -n get 192.168.1.249 | rg 'interface|gateway|flags'
```

## Done criteria before handoff
- `swift test` passes and `CamBar --probe` reports `live`.
- `./Scripts/deploy_app.sh` reports live video and no unsolicited UI.
- Presentation changes only: Josh confirms the popover and popout.
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
