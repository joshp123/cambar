# CamBar

> A tiny macOS menubar app that shows your RTSP camera live.
>
> <sub>[skip to agent copypasta](#give-this-to-your-ai-agent)</sub>

![CamBar preview](camera-pixelated2.jpg)

## The Magic

- **Menubar first.** A lightweight popover for quick checks, plus a full window for full-res viewing.
- **No cloud.** Everything is local: RTSP -> ffmpeg -> HLS -> AVPlayer.
- **Boring by design.** No auth flows, no accounts, no fluff. Just the camera.

## What it does

CamBar reads your RTSP URL (stored inside the app), starts `ffmpeg` to generate HLS segments, then plays them in a menubar popover and a standard window. It keeps playback pinned to the live edge so the feed stays current.

## First run

- Open the menubar popover.
- Click **Settings** and paste your RTSP URL.
- Close the sheet; the stream should start within a second or two.

## Requirements

- macOS 14+
- A reachable RTSP camera

Optional (auto-bundled when packaging if available on PATH):
- `ffmpeg`
- `camsnap`

## Run locally

```bash
./Scripts/compile_and_run.sh
```

## Configuration

CamBar stores settings in the app (UserDefaults). The only required setting is your RTSP URL.

Debug overrides:

```bash
export CAMBAR_RTSP_URL="rtsp://user:pass@camera-host:554/Streaming/Channels/101"
```

If no RTSP URL is set, CamBar will try to read `~/.config/camsnap/config.yaml` when present.

## Packaging

`Scripts/package_app.sh` bundles `ffmpeg` and `camsnap` into the app if they are available on PATH at build time. The runtime will prefer bundled binaries, then fall back to PATH.

## Zero to MVP (anonymized)

A short, sanitized prompt history from first request to a working menubar app:

1. **Prompt:** “Build a macOS menubar app to show a live RTSP camera.”
   **Outcome:** SwiftPM app scaffolded with menubar popover + full-size window.
2. **Prompt:** “Wire it to an RTSP camera using a local toolchain.”
   **Outcome:** RTSP → ffmpeg → HLS pipeline + local HTTP server.
3. **Prompt:** “Playback is static / stalls.”
   **Outcome:** HLS re-encode, live-edge watchdog, and playback restarts.
4. **Prompt:** “Make it feel like a real app.”
   **Outcome:** Settings sheet, bundled helpers, and cleaned README.

## Skill used

`https://github.com/Dimillian/Skills/tree/main/macos-spm-app-packaging`

## Give this to your AI agent

Copy this entire block and paste it to your agent:

```text
I want a tiny macOS menubar app that shows an RTSP camera live.

Repo: CamBar

What the app does:
- Menubar popover with live feed
- Optional full-size window for full-res viewing
- Uses ffmpeg to produce HLS locally, then AVPlayer for playback
- Stores settings inside the app (no external config required)

What I need you to do:
1) Build and run the app
2) Open Settings and paste my RTSP URL
3) Keep playback on the live edge (no drifting/stalls)
4) Ensure no credentials are committed

Notes:
- macOS 14+
- CAMBAR_RTSP_URL can override settings for debugging
```
