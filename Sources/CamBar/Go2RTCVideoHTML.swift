extension CameraPlaybackController {
    static func stopJavaScript() -> String {
        """
        window.__cambarStop && window.__cambarStop();
        """
    }

    static func html(generation: String) -> String {
        let streamName = Go2RTCRelayController.mainStreamName
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body, cambar-video, video {
              width: 100%;
              height: 100%;
              margin: 0;
              padding: 0;
              overflow: hidden;
              background: #000;
            }
            cambar-video { display: block; }
            video {
              display: block;
              object-fit: cover;
              pointer-events: none;
            }
          </style>
        </head>
        <body>
          <script type="module">
            import {VideoRTC} from './video-rtc.js';

            const generation = '\(generation)';
            const startedAt = performance.now();
            let pendingOpen = null;
            let sawFirstFrame = false;
            let lastFrameAt = performance.now();
            let stallReported = false;

            function emit(event, values = {}) {
              try {
                window.webkit.messageHandlers.cambarVideoEvent.postMessage({
                  generation,
                  event,
                  elapsed_ms: Math.round(performance.now() - startedAt),
                  ...values
                });
              } catch (_) {}
            }

            function watchFrames(video) {
              const onFrame = (_now, metadata) => {
                lastFrameAt = performance.now();
                stallReported = false;
                if (!sawFirstFrame && video.videoWidth > 0 && video.videoHeight > 0) {
                  sawFirstFrame = true;
                  emit('first_frame', {detail: JSON.stringify({
                    width: video.videoWidth,
                    height: video.videoHeight,
                    presentedFrames: metadata.presentedFrames
                  })});
                }
                if (pendingOpen) {
                  const open = pendingOpen;
                  pendingOpen = null;
                  emit('open_frame', {
                    token: open.token,
                    detail: JSON.stringify({
                      frame_wait_ms: Math.round(performance.now() - open.startedAt),
                      presentedFrames: metadata.presentedFrames,
                      mediaTime: metadata.mediaTime
                    })
                  });
                }
                video.requestVideoFrameCallback(onFrame);
              };
              video.requestVideoFrameCallback(onFrame);
            }

            class CamBarVideo extends VideoRTC {
              oninit() {
                super.oninit();
                this.video.controls = false;
                this.video.autoplay = true;
                this.video.muted = true;
                this.video.disablePictureInPicture = true;
                this.video.addEventListener('error', () => emit('video_error'));
                watchFrames(this.video);
              }
            }

            customElements.define('cambar-video', CamBarVideo);
            const player = document.createElement('cambar-video');
            player.mode = 'webrtc';
            player.media = 'video';
            player.background = true;
            player.visibilityCheck = false;
            player.src = new URL('api/ws?src=' + encodeURIComponent('\(streamName)'), location.href);
            document.body.appendChild(player);

            const stallTimer = setInterval(() => {
              if (sawFirstFrame && !stallReported && performance.now() - lastFrameAt > 2000) {
                stallReported = true;
                emit('frame_stalled');
              }
            }, 500);

            window.__cambarMarkOpen = token => {
              pendingOpen = {token, startedAt: performance.now()};
            };
            window.__cambarStop = () => {
              clearInterval(stallTimer);
              pendingOpen = null;
              try { player.ondisconnect(); } catch (_) {}
              try { player.remove(); } catch (_) {}
            };
          </script>
        </body>
        </html>
        """
    }
}
