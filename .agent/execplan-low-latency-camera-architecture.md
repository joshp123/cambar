# Finish CamBar as a tiny instant menu-bar camera viewer

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

This repository has `.agent/PLANS.md`; maintain this document according to that file. This plan replaces the earlier exploration framing with a finish-line plan: front-load stream warmup at login, make every later user action feel instant, and delete the overbuilt playback machinery that is no longer part of the product.

## Purpose / Big Picture

CamBar should be a tiny macOS menu-bar camera viewer. After login, it may spend 10-15 seconds quietly warming the camera streams, because Josh is not expected to click it during machine startup. After that warmup, clicking the menu-bar item or opening the popout should show current live video in under 0.5 seconds.

The product is the live camera feed. The app should not feel like a media player, a dashboard, a diagnostics console, or a camera management tool. It should have no play/pause/fullscreen media controls, no URL rows, no network-scanning UI, no preview architecture exposed to the user, and no stale-frame catch-up weirdness. Telemetry exists only to let the app self-diagnose whether it is meeting the speed goal and where time is being spent when it does not.

The old path was `RTSP camera -> ffmpeg -> local HLS files -> local HTTP server -> AVPlayer`. HLS means HTTP Live Streaming, a playlist plus media segment files. HLS is good for robust streaming, but it is the wrong normal path for this app because it waits for segment creation and player readiness before anything can be shown. The current end state is simpler: `RTSP camera -> bundled go2rtc helper -> direct live video surface`. `go2rtc` is a small camera relay process that keeps the RTSP stream warm and exposes browser-native live playback protocols such as WebRTC and MSE on localhost. WebRTC and MSE are media APIs that can display live video without CamBar writing HLS files.

## Progress

- [x] (2026-04-25 12:20Z) Confirmed the camera has HTTPS web UI and Hikvision-style ISAPI at `192.168.1.249`.
- [x] (2026-04-25 12:30Z) Confirmed camera streams: `101` full-resolution main, `102` low-resolution preview, and `103` mirroring main.
- [x] (2026-04-25 12:52Z) Measured local go2rtc preview preload at about 19 MB RSS and 0.0-0.1% CPU in a short sample.
- [x] (2026-04-25 14:20Z) Measured bundled go2rtc cold login warmup through the old HLS path at about 13.5 seconds before AVPlayer published preview. This is acceptable only during hidden login warmup.
- [x] (2026-04-25 14:21Z) Measured bundled go2rtc full-resolution through the old HLS path at about 4.6 seconds when started cold/on demand. This fails the post-login user-action target.
- [x] (2026-04-25 14:33Z) Changed bundled go2rtc config to preload both `cambar_preview` and `cambar_main`.
- [x] (2026-04-25 14:45Z) Identified CamBar's local HLS bridge as the main app-side bottleneck. Warm go2rtc full-resolution via CamBar HLS still took about 5.9 seconds, while direct go2rtc output returned first bytes in about 0.26 seconds.
- [x] (2026-04-25 15:05Z) Added a direct go2rtc video view prototype using a minimal WebKit media surface instead of visible go2rtc demo controls.
- [x] (2026-04-25 15:20Z) Updated this ExecPlan to remove exploration/fallback language and make the finish line explicit: warm at login, instant after warmup, delete old normal playback code.
- [x] (2026-04-25 13:36Z) Added direct-path telemetry at app, relay, WebKit navigation, first video frame, playing, and error points.
- [x] (2026-04-25 13:38Z) Measured warm direct menu open at about 417ms before deleting HLS, proving the architecture can hit the target when the viewer catches a keyframe quickly.
- [x] (2026-04-25 13:41Z) Deleted old normal-path HLS/ffmpeg source files and removed old preview/fallback stream derivation code.
- [x] (2026-04-25 13:44Z) Found that warming only go2rtc is not enough for deterministic sub-0.5s opens; new WebKit consumers can still wait 1.5-2.0s for a keyframe.
- [x] (2026-04-25 13:45Z) Added prewarmed menu/window WebKit views in tiny offscreen warm windows, so clicking attaches an already-playing view instead of starting a new viewer.
- [x] (2026-04-25 13:45Z) Captured a screenshot at `/tmp/cambar-shots/cambar-menu.png` showing the live menu-bar camera UI with no media controls.
- [x] (2026-04-25 13:49Z) Measured repeated menu opens after WebKit prewarm. First open attached the prewarmed view immediately; repeated screenshot checks showed live video instead of black.
- [x] (2026-04-25 13:50Z) Verified process state after deletion: normal app shows `CamBar` plus bundled `go2rtc`, with no `ffmpeg` or HLS process.
- [x] (2026-04-25 13:51Z) Ran the full local gate with `nix shell nixpkgs#go2rtc -c ./Scripts/compile_and_run.sh --test` and left the packaged app running.
- [x] (2026-04-25 14:29Z) Review pass removed leftover preview/config API surface, serialized telemetry writes, narrowed the go2rtc helper environment, and updated this plan to match the main-only implementation.
- [x] (2026-04-25 14:35Z) Review pass deleted the hidden Bonjour local-network prompter and replaced the visible `Pop Out` text button with a smaller icon affordance.
- [ ] (2026-04-25 14:42Z) Visual review caught a blocker: the warm WebKit video surface can log `playing` while the captured menu window is black. This must be fixed before the app is considered polished.

## Surprises & Discoveries

- Observation: Cold startup was not slow because Swift process creation was slow.
  Evidence: Earlier telemetry showed `ffmpeg` launched in tens of milliseconds, while first HLS playlist/player readiness took seconds.

- Observation: The camera's keyframe intervals explain part of the cold-start delay.
  Evidence: Stream `101` is 2688x1520 H.264 at 25fps with GOP 50, roughly a 2-second keyframe interval. Stream `102` is 640x360 H.264 at 10fps with GOP 40, roughly a 4-second keyframe interval. A decoder often needs a keyframe before it can show a clean first frame.

- Observation: Hidden login warmup changes the product problem.
  Evidence: Josh explicitly accepts 10-15 seconds during machine startup. Therefore the hard target is not cold camera connection time; it is warm post-login open time.

- Observation: Preloading both streams in go2rtc appears cheap enough for this personal utility.
  Evidence: A clean local sample with both preview and main preloaded used about 22-23 MB RSS and 0.1-0.4% CPU.

- Observation: The overbuilt part is the local HLS bridge, not the bundled relay.
  Evidence: The path `go2rtc -> ffmpeg -> HLS files -> local HTTP server -> AVPlayer` still took about 5.9 seconds to publish full-resolution even when go2rtc was already warm. Direct go2rtc main output returned first bytes in about 0.26 seconds.

- Observation: A WebKit media surface is currently the least overbuilt direct playback option.
  Evidence: Native `AVPlayer` does not play RTSP/WebRTC/MSE directly. A fully native alternative would require embedding and maintaining a heavier playback stack such as libwebrtc, mpv, or VLC. The current WebKit use is not product UI HTML; it is a thin decoder surface for the live video API go2rtc already exposes.

- Observation: go2rtc stream preload does not guarantee deterministic first-frame time for a brand-new WebKit consumer.
  Evidence: After deleting the HLS path, a warm menu open took about 1.49s because the newly-created WebKit viewer still had to wait for a decodable H.264 keyframe. This matches the camera's roughly 2s main-stream GOP.

- Observation: The useful warmup boundary is the visible decoder surface, not just the relay.
  Evidence: Keeping WebKit views alive in tiny offscreen warm windows let the app log `playing` during login warmup. Later menu open logged `view_attached` immediately rather than creating a new player.

## Decision Log

- Decision: Accept login-time stream warmup and optimize only post-warm user actions for `<0.5s`.
  Rationale: Waiting during computer startup is acceptable. Waiting after clicking the menu-bar app is not.
  Date/Author: 2026-04-25 / Codex

- Decision: Bundle and control go2rtc inside CamBar rather than require a separate server.
  Rationale: This keeps the app self-contained and avoids a multi-box home-server setup. Local measurements show the helper is small enough to run continuously.
  Date/Author: 2026-04-25 / Codex

- Decision: Preload the main stream `101` at app launch/login.
  Rationale: The success criterion is instant full-resolution live video after warmup. The preview stream is not part of the product path, so keeping it warm is unnecessary background work.
  Date/Author: 2026-04-25 / Codex

- Decision: Simplify to the main stream only for normal product playback.
  Rationale: The menu successfully renders `cambar_main` directly, and the product goal is full-resolution-fast. Keeping a preview stream after that point is dead architecture.
  Date/Author: 2026-04-25 / Codex

- Decision: Prewarm the WebKit video surfaces, not only go2rtc.
  Rationale: A new WebKit consumer can still wait for the next keyframe. Prewarming the actual view moves that wait to login/startup where it is acceptable.
  Date/Author: 2026-04-25 / Codex

- Decision: Remove, not quarantine, the old HLS/ffmpeg normal playback path after direct playback is proven.
  Rationale: Josh's priority is minimal code and no overbuilt fallbacks. Keeping unused playback architectures increases cognitive load and makes future bugs harder to diagnose.
  Date/Author: 2026-04-25 / Codex

- Decision: Keep telemetry simple and local.
  Rationale: The app only needs to answer "was the stream ready fast enough?" and "where was time spent?" A single local JSONL log is enough; metrics backends, dashboards, and feature flags are out of scope.
  Date/Author: 2026-04-25 / Codex

- Decision: Do not change camera settings in this plan.
  Rationale: The camera is already compatible with a warm relay approach. Changing GOP/codec/bitrate could affect other consumers and is not needed to hit the post-login target.
  Date/Author: 2026-04-25 / Codex

## Outcomes & Retrospective

The implementation now uses bundled go2rtc and direct WebKit video surfaces for normal playback. The old HLS/ffmpeg source files were deleted. Telemetry showed the first actual decoder warmup still takes about 1.6-2.0 seconds after relay warm, which matches the main stream keyframe interval, so the app now front-loads both the relay and the WebKit video surfaces. Repeated menu screenshots show live video with no media controls. The remaining product judgment is whether the visible `Pop Out` button should stay or become a less visible affordance.

Review update: the architecture is smaller, but the visible renderer is not yet acceptable. On 2026-04-25, screenshot QA captured a black menu window while telemetry still showed `playing`. The next implementation pass should treat "first visible non-black camera pixels in the menu window" as the acceptance signal, not only WebKit media events.

## Context and Orientation

CamBar lives at `/Users/josh/code/macos-cam-app`. It is a SwiftPM macOS app packaged by scripts in `/Users/josh/code/macos-cam-app/Scripts`.

Important files in the current working tree:

- `/Users/josh/code/macos-cam-app/Sources/CamBar/AppDelegate.swift` owns app startup, menu-bar wiring, login behavior, relay startup, and provider creation.
- `/Users/josh/code/macos-cam-app/Sources/CamBar/Go2RTCRelayController.swift` owns the bundled `go2rtc` helper process and localhost config.
- `/Users/josh/code/macos-cam-app/Sources/CamBar/Go2RTCVideoView.swift` owns the direct live video surface.
- `/Users/josh/code/macos-cam-app/Sources/CamBar/ContentView.swift` owns the menu popover UI.
- `/Users/josh/code/macos-cam-app/Sources/CamBar/CameraWindowController.swift` owns the popout window.
- `/Users/josh/code/macos-cam-app/Sources/CamBar/LoginItemController.swift` registers the app to start at login when packaged.
- `/Users/josh/code/macos-cam-app/Sources/CamBarCore/StreamSourceResolver.swift` resolves the configured RTSP source and cache/tool paths.
- `/Users/josh/code/macos-cam-app/Sources/CamBarCore/DirectStreamTelemetry.swift` writes local JSONL stream telemetry.
- The old normal playback files `CameraFrameProvider.swift`, `HLSServer.swift`, `LiveVideoView.swift`, and `StreamStatusView.swift` have been deleted. Do not reintroduce HLS/ffmpeg fallback code for normal playback.
- `/Users/josh/code/macos-cam-app/Tests/CamBarTests/CamBarTests.swift` contains behavior tests and must be kept passing.

Known camera streams:

- `101`: full-resolution main stream, H.264, 2688x1520, 25fps, bitrate 6144, GOP 50.
- `102`: preview/substream, H.264, 640x360, 10fps, bitrate 256, GOP 40.
- `103`: exists, but currently mirrors main settings and is not useful.

The target runtime flow is:

1. macOS login starts CamBar.
2. CamBar starts bundled `go2rtc` bound to localhost only.
3. `go2rtc` connects to the camera and preloads `cambar_main`.
4. CamBar records when the relay and main stream become warm.
5. Later, clicking the menu-bar item shows live video from the already-warm relay in under 0.5 seconds.
6. Opening the popout shows full-resolution live video from the already-warm relay in under 0.5 seconds.
7. Normal playback does not start `ffmpeg`, create HLS files, or depend on `HLSServer`.

## Plan of Work

First, make the direct path observable. Add one small telemetry writer for direct playback events. It should append JSON lines to a file under `~/Library/Caches/CamBar/`, redact secrets, serialize writes, and record elapsed milliseconds where the WebKit surface can provide them. It should log app launch, go2rtc process start, go2rtc API readiness, main warm, menu view creation, popout view creation, video `loadeddata`, video `playing`, and video errors. The code should be boring: no metrics backend, no sampling, no async pipeline beyond a simple file-write queue.

Second, measure the direct path against the real target. Start the packaged app normally, allow login-style warmup to finish, then open the menu and popout. The measurement must report elapsed time from user-visible view creation to first video frame and playing. Acceptance is `<0.5s` for warm menu open and `<0.5s` for warm popout open. If the target fails, diagnose from the telemetry before changing code.

Third, enforce the minimal architecture. Once direct warm playback is measured, remove old normal playback code instead of preserving it. Delete the old HLS server/provider/player files if no tests or debug commands still require them. If some source-resolution utility remains useful, move only that utility into a small surviving file and delete the rest. `ContentView`, `CameraWindowController`, and `AppDelegate` should not branch between HLS and direct playback for normal use.

Fourth, simplify UI. The menu and popout should be video-first. Remove media controls, raw source URLs, status rows, and diagnostic text from the normal state. Keep only the smallest necessary app controls, such as a way to open the popout or close the window, and only show text when there is a real error. The visual standard is: when it works, Josh sees camera video, not app machinery.

Fifth, make visual QA agent-owned. Add or document a repeatable command that launches CamBar, captures the menu or popout, and writes a screenshot under `/tmp/cambar-shots/`. Prefer the Computer Use plugin when it can target the app. If the plugin cannot inspect a menu-bar-only LSUIElement app, use a deterministic macOS screenshot/crop fallback and document that fallback in this plan and README.

Sixth, update docs and tests. Keep `/Users/josh/code/macos-cam-app/AGENTS.md` aligned with the north star. Update README only for behavior the user needs: packaging, login start, where telemetry lives, and how to run the local verification. Run the full gate before handoff.

## Concrete Steps

Work from `/Users/josh/code/macos-cam-app`.

Inspect the current dirty tree before editing:

    git status --short
    git --no-pager diff --color=never

Add direct telemetry:

    Edit Sources/CamBar/Go2RTCVideoView.swift so the WebKit video surface sends script messages for first frame, playing, and errors.
    Add or reuse a tiny Swift telemetry writer under Sources/CamBar or Sources/CamBarCore.
    Log to ~/Library/Caches/CamBar/direct-stream-events.jsonl.
    Do not log RTSP usernames, passwords, or full URLs.

Measure warm behavior:

    ./Scripts/compile_and_run.sh --test
    ./Scripts/package_app.sh
    open ./dist/CamBar.app
    sleep long enough for warmup, usually 15 seconds.
    Open the menu or popout using the app's existing debug hooks or Computer Use.
    tail -80 "$HOME/Library/Caches/CamBar/direct-stream-events.jsonl"

Inspect process state without leaking credentials:

    ps -axo pid,pcpu,pmem,command | rg 'CamBar|ffmpeg|go2rtc|master\\.m3u8' | rg -v 'rg ' | sed -E 's#rtsp://([^:[:space:]/@]+):[^@[:space:]]+@#rtsp://\\1:***@#g'

Expected normal-path result after deletion:

    go2rtc is present.
    CamBar is present.
    ffmpeg is absent unless a deliberately named diagnostic command is running.
    No new HLS segment files are created during ordinary menu or popout use.

Capture screenshots:

    Prefer the Computer Use plugin for a live app screenshot.
    If Computer Use times out on the LSUIElement app, use macOS screencapture plus a deterministic crop of the CamBar window.
    Write screenshots to /tmp/cambar-shots/ and inspect them before handoff.

Run the final gate:

    swift test -q
    ./Scripts/compile_and_run.sh --test

## Validation and Acceptance

The plan is accepted only when all of these are true:

- CamBar starts at login when packaged.
- After a 10-15 second login-style warmup, opening the menu shows live video in under 0.5 seconds.
- After the same warmup, opening the popout shows full-resolution live video in under 0.5 seconds.
- Telemetry records app launch, relay startup, stream warm state, view open, first video frame, playing, and errors in a local JSONL file.
- Normal visible playback does not start `ffmpeg`, write HLS files, or use `HLSServer`.
- Old HLS/ffmpeg normal playback code is deleted, not kept as a silent fallback.
- The menu and popout show video without media controls or diagnostic clutter.
- A fresh agent can take or produce a screenshot of the running app without Josh intervening.
- `swift test -q` passes.
- `./Scripts/compile_and_run.sh --test` passes.
- No RTSP credentials appear in process listings, logs, diffs, docs, or screenshots.

## Idempotence and Recovery

All local tests and app launches are safe to repeat. `go2rtc` must bind only to localhost. If a prior CamBar-owned `go2rtc` process is still running, the app may stop and restart that helper. Do not kill unrelated processes.

Telemetry files are disposable and live under `~/Library/Caches/CamBar/`. Screenshots are disposable and live under `/tmp/cambar-shots/`.

Do not change camera settings for GOP, codec, resolution, bitrate, or credentials under this plan. If direct warm playback fails the target, diagnose app and relay timing first. Camera setting changes require a separate explicit decision.

If Computer Use cannot screenshot CamBar because menu-bar apps are hard to target, record the failure and use the macOS screenshot fallback. The requirement is agent-owned visual verification, not a specific screenshot tool.

## Artifacts and Notes

Current measured evidence:

    Bundled go2rtc preview warmup through old HLS path: about 13.5s.
    Bundled go2rtc main/full-res through old HLS path: about 4.6s cold/on demand.
    Warm go2rtc main through CamBar old HLS path: about 5.9s.
    Direct go2rtc main first bytes: about 0.26s.
    go2rtc with preview+main preloaded: about 22-23 MB RSS, 0.1-0.4% CPU in short samples.

Prior screenshot evidence:

    /tmp/cambar-shots/cambar-window-verified.png showed the stock go2rtc demo controls and proved why that UI was wrong.
    /tmp/cambar-shots/cambar-window-nocontrols.png showed the custom no-controls video surface, but the capture was partially occluded. A clean repeatable screenshot is still required.

The phrase "warm stream" means go2rtc is already connected to the camera and has enough live video data that a new local viewer does not wait for camera connection, authentication, or the next useful keyframe.

## Interfaces and Dependencies

CamBar should depend on the bundled `go2rtc` executable when packaged. The packaging script must place it under the app bundle resources, currently expected as `CamBar.app/Contents/Resources/bin/go2rtc`.

The surviving playback interface should be direct and small. The UI needs only enough surface to say:

    Show the menu live view.
    Show the full-resolution popout.
    Report whether the stream is warming, ready, or failed.

The UI should not know about HLS segment paths, ffmpeg arguments, GOP intervals, RTSP credentials, or camera-specific ISAPI endpoints.

The direct telemetry event shape should be small and stable, for example:

    {"time":"2026-04-25T15:30:00Z","component":"direct-video","stream":"cambar_main","event":"playing","elapsed_ms":184}

Names can change, but the log must be machine-readable, local, and credential-free.

## Revision Notes

2026-04-25 / Codex: Rewrote the plan around Josh's clarified goal: front-load warmup at login, make post-warm use instant, keep the product tiny, delete old overbuilt normal playback code, add enough telemetry and screenshot capability for agent-owned diagnosis, and avoid camera setting changes or fallback architecture unless a separate decision is made.
