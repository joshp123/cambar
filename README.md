# CamBar

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)

> A tiny macOS menubar app that shows your RTSP camera live.
>
> <sub>[skip to agent copypasta](#give-this-to-your-ai-agent)</sub>

![CamBar preview](camera-pixelated2.jpg)

## The Magic

- **Menubar first.** A lightweight popover for quick checks, plus a full window when needed.
- **Launches at login.** Once opened as a packaged app, CamBar registers itself with macOS Login Items.
- **No cloud.** Everything is local: RTSP camera -> bundled go2rtc -> direct live video surface.
- **Boring by design.** No auth flows, no accounts, no fluff. Just the camera.

## What it does

CamBar reads your RTSP URL from `CAMBAR_RTSP_URL` or `~/.config/camsnap/config.yaml`, starts bundled `go2rtc`, warms the main camera stream at launch/login, and shows that already-running stream in the menu bar. Normal playback does not use `ffmpeg`, HLS files, or AVPlayer.

## Why

I wanted to know when the postman is at the door. The vendor app for this camera is awful, HomeKit Secure Video is also painful, and I can ship a tiny local viewer in ~10 minutes while Codex is grinding on other projects.

## First run

- Open the menubar popover after the app has had a few seconds to warm the stream.
- Set `CAMBAR_RTSP_URL` if you want to override camera discovery.
- The stream should already be live when the popover opens.
- macOS may show CamBar under System Settings -> General -> Login Items if approval is needed.

## Requirements

- macOS 14+
- A reachable RTSP camera

If you build from source, `go2rtc` must be on `PATH` at package time and is bundled into the app. The repo's `devenv.nix` provides it.

## Run locally

```bash
./Scripts/compile_and_run.sh
```

## Configuration

CamBar reads RTSP in this order:
1) `CAMBAR_RTSP_URL`
2) `~/.config/camsnap/config.yaml`

Debug overrides:

```bash
export CAMBAR_RTSP_URL="rtsp://user:pass@camera-host:554/Streaming/Channels/101"
CAMBAR_OPEN_POPOVER=1 ./CamBar.app/Contents/MacOS/CamBar
./Scripts/debug_popover.sh
```

If neither source is available, startup shows an error with the missing path.

## Packaging

`Scripts/package_app.sh` requires `go2rtc` on `PATH` and bundles it into `CamBar.app/Contents/Resources/bin/go2rtc`. Use:

```bash
nix shell nixpkgs#go2rtc -c ./Scripts/compile_and_run.sh --test
```

Timing telemetry is written to `~/Library/Caches/CamBar/direct/direct-stream-events.jsonl`.

## Zero to MVP (anonymized prompts)

Raw prompt history (user messages only, with sensitive values redacted). Timestamps are ISO‑8601 and approximate.

```
2026-01-07T18:02:00Z use the macos-spm-app-pacakging skill and check the codexbar repo in our reserach directory under code.
2026-01-07T18:02:10Z i want to create an app where i can view my camera live in macos. the camera is readable using camsnap. can you investigate whats on disk first, find the camera, and then suggest how you would create the app? should have a menubar like codex too i think, with the camera feed.
2026-01-07T18:14:40Z wrong camera. its a network camera. check how my clawdbot instance talks to it. this is an imporant change.
2026-01-07T18:15:05Z choose sensible defaults for all.
2026-01-07T18:15:15Z do it.
2026-01-07T18:21:30Z what about a small regular macos app window too? so we can see full resolution vid. campsnap should already be installed and available, but the app can't find it, so can you wire it up?
2026-01-07T18:23:02Z 1. do that or just wire in camsnap binary? thats kinda annoying i dont want to click this shit.
2026-01-07T18:23:03Z 2. yes we want live vidoe plz.
2026-01-07T18:25:11Z wire the whole thing up and link to the cam. go find it. i dont care about the detilas i just want the cam in my menubar
2026-01-07T18:26:44Z i dont get any video playback?
2026-01-07T18:26:44Z 1. yes
2026-01-07T18:26:44Z 2. yes
2026-01-07T18:27:18Z password wrong. needs trailing exclamation mark [REDACTED]
2026-01-07T18:28:09Z still doesn't stream for me now? try with the old passowrd i guess?
2026-01-07T18:31:22Z its buggy. i get a small static image (no feed) then when i click reload i get a ffmpeg255 error. plz fix
2026-01-07T18:49:10Z verify ui playback plz
2026-01-07T18:52:31Z i just see spinning loader
2026-01-07T18:59:44Z nope. it loads but its still a static image. theres a clock in top left and it doesn't increase
2026-01-07T19:07:12Z no looks good to me. lets create a new repo for this. then make sure there's no PII, add a readme like gohome, then commit and push
2026-01-07T19:12:01Z [camera-pixelated2.jpg 726x490]  -> add this to readme.
2026-01-07T19:12:02Z ffmpeg on PATH (or set in config)
2026-01-07T19:12:02Z A reachable RTSP camera
2026-01-07T19:12:02Z Optional: camsnap config for camera discovery
2026-01-07T19:12:03Z -> can't we just pacakage this in the app?
2026-01-07T19:12:04Z config is bad too. should exist just in the app imo?
2026-01-07T19:12:05Z ... also we wanna share an anonymozied (no PII) version of "zero to MVP" with our prompt history in the readme, as well as linking https://github.com/Dimillian/Skills/tree/main/macos-spm-app-packaging -> this skill.
2026-01-07T19:18:22Z image is in /tmp/.
2026-01-07T19:23:40Z readme needs fixing tho. shouldn't need an AI coding agent to wire it up tbh lol. (i mean i guess you can)
2026-01-07T19:27:05Z rebuild app and open it for me
2026-01-07T19:31:18Z zero to mvp needs to include REAL prompts.
2026-01-07T19:31:19Z (but still anyonymoized so no PII)
2026-01-07T19:35:50Z no those are too sanitized. nobody cares about outcome. just show the prompts. raw. (except for passwords etc). with iso8601 timestamps.
```

## Skill used

`https://github.com/Dimillian/Skills/tree/main/macos-spm-app-packaging`

## Optional: give this to an AI agent

You do **not** need an AI agent to use CamBar. It’s here only if you want automated setup or changes.

```text
I want a tiny macOS menubar app that shows an RTSP camera live.

Repo: CamBar

What the app does:
- Menubar popover with live feed
- Optional full-size window
- Bundles go2rtc and prewarms the main RTSP stream at app launch/login
- Renders the warmed stream directly; no normal-path ffmpeg/HLS/AVPlayer

What I need you to do:
1) Build and run the app
2) Set CAMBAR_RTSP_URL (or verify camsnap config)
3) Verify warm menu open is effectively instant
4) Ensure no credentials are committed

Notes:
- macOS 14+
- CAMBAR_RTSP_URL can override discovery for debugging
```

## License

AGPL-3.0. See `LICENSE`.
