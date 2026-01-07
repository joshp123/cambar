# CamBar

> A tiny macOS menubar app that shows your RTSP camera live.
>
> <sub>[skip to agent copypasta](#give-this-to-your-ai-agent)</sub>

## The Magic

- **Menubar first.** A lightweight popover for quick checks, plus a full window for full-res viewing.
- **No cloud.** Everything is local: RTSP -> ffmpeg -> HLS -> AVPlayer.
- **Boring by design.** No auth flows, no accounts, no fluff. Just the camera.

## What it does

CamBar reads your camera config (or an RTSP URL), starts `ffmpeg` to generate HLS segments, then plays them in a menubar popover and a standard window. It keeps playback pinned to the live edge so the feed stays current.

## Requirements

- macOS 14+
- `ffmpeg` on PATH (or set in config)
- A reachable RTSP camera
- Optional: `camsnap` config for camera discovery

## Run locally

```bash
./Scripts/compile_and_run.sh
```

## Configuration

CamBar reads `~/.config/camsnap/config.yaml` by default. If you want to bypass camsnap, set:

```bash
export CAMBAR_RTSP_URL="rtsp://user:pass@camera-host:554/Streaming/Channels/101"
```

You can also set explicit binary paths in:

```
~/Library/Application Support/CamBar/config.json
```

Example:

```json
{
  "ffmpegPath": "/opt/homebrew/bin/ffmpeg",
  "camsnapPath": "/opt/homebrew/bin/camsnap"
}
```

## Give this to your AI agent

Copy this entire block and paste it to your agent:

```text
I want a tiny macOS menubar app that shows an RTSP camera live.

Repo: CamBar

What the app does:
- Menubar popover with live feed
- Optional full-size window for full-res viewing
- Uses ffmpeg to produce HLS locally, then AVPlayer for playback

What I need you to do:
1) Build and run the app
2) Wire it to my RTSP camera (use CAMBAR_RTSP_URL or camsnap config)
3) Keep playback on the live edge (no drifting/stalls)
4) Ensure no credentials are committed

Notes:
- ffmpeg must be on PATH or set in config.json
- macOS 14+
```
