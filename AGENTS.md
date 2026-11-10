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
- Route (`Sources/CamBar/CameraRoute.swift`), chosen at the start of every
  session:
  - direct over the home network when an interface is on the camera's subnet
    and the device answering there presents the camera's HTTPS certificate
    and completes a TLS handshake with it, which proves it holds the camera's
    private key. The certificate is learned only through Tailscale, the one
    authenticated path, and stored in UserDefaults
    (`cameraCertificateSHA256.<host>`); learning or relearning it switches a
    Tailscale session to direct at once
  - otherwise through Tailscale, pinned to the `utun` interface, so a hotel or
    Airbnb network that reuses 192.168.1.0/24 never receives the camera login
  - with neither, CamBar does not connect (`route_chosen route=unavailable`).
    `CameraRoutePolicy` in CamBarCore is this rule, with tests
  - a network change is acted on only after it settles for 2 s, and only if the
    route changed or there is no working session; flapping interfaces never cut
    a working stream
  - retries back off 0.1, 0.5, 2, 5, 10, 20, 40, then every 60 s; opening the
    menu, waking and a settled network change retry at once
- Stream policy:
  - the main stream `/Streaming/Channels/101` is warmed at launch/login
  - one stream runs at a time; when main slips 3 s behind real time, or fails
    three times running, CamBar falls back to the substream `/102`. It tries
    main again after 5 minutes, on wake and on any network change
  - while no surface is visible, keep receiving but do not decode: hold only
    the compressed frames since the last keyframe. On open, decode those
    without output and show the newest, then continue live
  - in macOS Low Power Mode nothing streams while the menu is closed; opening
    connects from cold (about 0.6 s at home, 1 to 2 s over Tailscale) and
    closing disconnects. Josh's MacBook turns Low Power Mode on whenever it is
    on battery, so this is the normal behaviour on battery; he chose to keep
    it. `CAMBAR_LOW_POWER_MODE=1` simulates it for
    `--probe` and `Scripts/ui_probe.sh`
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

Never screenshot from a probe or run a GUI binary outside its app bundle: both
can bring windows forward. Use the tools below. The Mac mini is at home on the
camera's LAN, good for ffmpeg and network checks, but it runs macOS 26 and
CamBar needs 27.

1. `swift test` for the reducers, parsers and frame policy.
2. `CamBar --probe [seconds]` for the stream pipeline and route: the same
   `CameraStreamController` and VideoToolbox decoder as the app, with no UI and
   no effect on the running app. stderr is the telemetry; stdout is one JSON
   line (`result`: `live`, `stalled`, `no_video` or `no_camera_configured`;
   `first_frame_ms`, `hidden_cpu_percent`, `reveal_ms`, `viewing_fps`,
   `viewing_cpu_percent`, size, `retries`, `route`). It stays hidden for `seconds`,
   measures five reveals, then watches for 5 s. It saves `reveal_png`, the first
   picture of a reveal, and `last_frame_png`, with `last_frame_decoded_at`.
   Open the PNG: the camera prints its clock top left, so the difference is
   the real end-to-end latency, and you can see black, garbled or frozen video.
   Set `CAMBAR_RTSP_URL` to probe another stream (`/Streaming/Channels/102` is
   the substream). Use `~/Applications/CamBar.app/Contents/MacOS/CamBar --probe`
   to test the installed build.
3. The running app's log, `~/Library/Caches/CamBar/direct/direct-stream-events.jsonl`
   (also in `log show --predicate 'subsystem == "com.cambar"'`). Filter by the
   newest `launch` event's `session_id`. What to read:
   - `network_changed`: interfaces with their addresses (`utun*` is Tailscale).
   - `route_chosen`: `direct`, `tailscale` or `system`, with the reason (for
     example "camera certificate matches" or "device at … is not the camera").
     `camera_certificate_learned` and `camera_certificate_changed` mark learning.
   - `rtsp diagnostic "TCP connected <local>(me)-><camera>"`: which address
     reached the camera. A `100.x` local address means Tailscale.
   - `session_stopped`: the real failure ("camera did not answer within 5 s",
     "no video for 5 s", or the socket error), with `[interface=… local=…]` for
     connection failures, plus duration, frame and byte counts and
     `last_packet_age_ms`. Framing errors include the next raw bytes.
   - `frame_heartbeat` every 5 s: `stream` (`main` or `fallback`),
     `real_time_ratio` (video seconds received per wall second), `seconds_behind`
     (cumulative slip this session; 3 triggers fallback), `cpu_percent`, `memory_mb`, `encoded_kbps`, frame counts.
     Main needs about 4.5 Mbit/s by day and up to 6 at night; the substream under 1 Mbit/s.
   - `stream_switched`: a move between main and the substream, with the reason.
   - `live_view.elapsed_ms`: click-to-live time.
4. `Scripts/ui_probe.sh` for presentation code. It runs the real popover
   content and video surface in an invisible off-screen window from the signed
   bundle, and fails if CamBar ever becomes frontmost. It reports
   `open_to_live_ms` over five opens, forces a switch to the substream, and
   saves the view tree and video pictures as PNGs (the view-tree PNG shows the
   badge and controls; the video area is black there because the video layer
   does not render into it). It cannot cover NSPopover or the status item.
5. `Scripts/smoke_ui.sh` drives the real popover on screen. Last resort only.

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
  - one app-lifetime RTSP session, hardware H.264/H.265 decode, latest-frame cache, reconnect supervision and main/substream fallback
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

## Resource target
With the menu closed, CamBar stays at or under 3% of one CPU core and 150 MB,
and `VTDecoderXPCService` stays at 0 because nothing is decoded.
`frame_heartbeat` reports `cpu_percent` and `memory_mb`. Opening stays under
500 ms. `Scripts/deploy_app.sh` checks all three with the installed binary's
probe, which runs whatever the Mac's power mode. On the direct route at home
the release probe measures about 1.7% hidden at 5 to 6 Mbit/s, and Tailscale
does no work for CamBar.

Measured 30-31 Oct 2026, hidden, stream keeping up (`real_time_ratio` near 1),
all on efficiency cores:
- main at 4 Mbit/s (cap 4096 then): 1.3% in the release probe; the app overnight was 2.9%
  median before the depacketiser fix below, so expect about 2.3%
- substream at 0.7 Mbit/s: 0.7%
- open to live view: 74 to 125 ms with the real surface
- viewing: about 4% plus about 2% in the decoder process
- energy, hidden, from the kernel counter (`Scripts/Support/ProcessEnergy.swift`):
  1.5 to 3 mW for CamBar. Tailscale's extension (root, unreadable) uses about
  twice CamBar's CPU decrypting the stream away from home. Together well under
  10 mW, about 0.3% of the 84 Wh battery per day. The unmeasured cost is the
  Wi-Fi radio, kept awake by a packet every 40 ms on either stream.
  System-wide `SystemPowerIn` from ioreg is too coarse to see this

What the hidden cost is (Instruments Time Profiler): about 40% Apple's
in-process TCP stack, 25% RTP depacketising, the rest allocation and copying.
Fixed so far: decoding while hidden (removed), a socket read per packet (now
16 KB batches), and the RTSP client copying its depacketiser on every packet.
A starved stream looks cheaper than it is, so measure with the stream keeping
up. Profile with `xcrun xctrace record --template 'Time Profiler' --attach
<pid> --time-limit 20s`; `sample` cannot tell running from waiting. CPU
blowouts drove the rewrite away from ffmpeg and WebKit, so treat a miss as a
bug.

## Camera settings (not in this repo)
Main: H.265, 2688x1520, 25 fps, VBR max 6144 kbit/s, keyframe every 2 s, Smart
Codec off. Chosen by SSIM and PSNR of static regions against a high-bitrate
reference, by day and by night (`ssh mac-mini '~/cambar-quality/compare'`
reruns it; results in `~/cambar-quality/runs/`). At night 4096 beat the old
H.264 at 6144, but in daylight on 31 Oct it fell short in every region, worst
on the left-hand texture. H.265 at 6144 beat the old H.264 everywhere by day
(SSIM 0.992 vs 0.985) at about the same measured bitrate (4.5 vs 4.3 Mbit/s).
Moving areas are masked out, so motion is not scored. Sub: H.264 Main, 1280x720, 25 fps, VBR max 1024 kbit/s, keyframe every
2 s, so Apple Home's live view can use it without conversion. Its averaged
daylight picture scored at least as close to the main stream as the H.265
substream did (SSIM 0.83 vs 0.79), with the same visible detail. Keep Smart Codec off: it stretches keyframe spacing and slows first frame.

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
- read `route_chosen` first. At home it should be `direct`; if it says
  "certificate not learned yet" the next session after a Tailscale connection
  goes direct. Away it should be `tailscale`
- `nc -b en0 -zv 192.168.1.249 554` tests the direct path and
  `nc -b utun6 -zv 192.168.1.249 554` the Tailscale path, whatever the routing
  table prefers
- ping fails -> routing/ACL/subnet-router problem
- ping ok + port fails -> camera/RTSP path/firewall problem
- ping ok + port ok + app fails -> CamBar RTSP/decode/presentation logic

## Travel/remote notes (Tailscale)
- Subnet router != exit node.
- CamBar needs reachability to camera `192.168.1.249:554`; exit node not required.
- Known current topology: `josh-nas` advertises `192.168.1.0/24` and the
  camera's `192.168.1.249/32`. CamBar pins each connection to an interface,
  so it does not depend on which route macOS prefers; the /32 keeps other
  tools on a borrowed 192.168.1.0/24 network pointed at Tailscale.
- Away from home the warm stream carries the camera bitrate over Tailscale
  for as long as CamBar runs, unless Low Power Mode is on.
- Helpful checks:
```bash
tailscale debug prefs | jq '{WantRunning,RouteAll,ExitNodeID,ExitNodeAllowLANAccess}'
route -n get 192.168.1.249 | rg 'interface|gateway|flags'
```

## Done criteria before handoff
- `swift test` passes and `CamBar --probe` reports `live`.
- `./Scripts/deploy_app.sh` reports live video within the targets and no
  unsolicited UI.
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
