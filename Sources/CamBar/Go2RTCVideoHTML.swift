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
            let stallTimer = null;

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
              function sampleFrame() {
                try {
                  const canvas = document.createElement('canvas');
                  canvas.width = 32;
                  canvas.height = 18;
                  const context = canvas.getContext('2d', {willReadFrequently: true});
                  context.drawImage(video, 0, 0, canvas.width, canvas.height);
                  const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
                  let dark = 0;
                  let color = 0;
                  const total = pixels.length / 4;
                  for (let index = 0; index < pixels.length; index += 4) {
                    const red = pixels[index];
                    const green = pixels[index + 1];
                    const blue = pixels[index + 2];
                    if (Math.max(red, green, blue) < 16) dark += 1;
                    if (Math.max(red, green, blue) - Math.min(red, green, blue) > 12) color += 1;
                  }
                  const detail = JSON.stringify({
                    darkRatio: dark / total,
                    colorRatio: color / total
                  });
                  emit('frame_sample', {detail});
                  if (dark / total > 0.98) {
                    emit('black_frame_suspected', {detail});
                  }
                } catch (error) {
                  emit('frame_sample_failed', {detail: String(error)});
                }
              }

              function noteFrame(presentedFrames) {
                lastFrameAt = performance.now();
                if (stallReported) emit('frame_resumed');
                stallReported = false;
                if (!sawFirstFrame && video.videoWidth > 0 && video.videoHeight > 0) {
                  sawFirstFrame = true;
                  emit('first_frame', {detail: JSON.stringify({
                    width: video.videoWidth,
                    height: video.videoHeight,
                    presentedFrames
                  })});
                }
              }

              function completeOpen(token, values) {
                if (!pendingOpen || pendingOpen.token !== token) return;
                const open = pendingOpen;
                pendingOpen = null;
                emit('frame_candidate', {
                  token: open.token,
                  detail: JSON.stringify({
                    frame_wait_ms: Math.round(performance.now() - open.startedAt),
                    ...values
                  })
                });
                setTimeout(sampleFrame, 0);
              }

              const onFrame = (_now, metadata) => {
                noteFrame(metadata.presentedFrames);
                if (pendingOpen) {
                  const token = pendingOpen.token;
                  const values = {
                    presentedFrames: metadata.presentedFrames,
                    mediaTime: metadata.mediaTime,
                    source: 'video_frame_callback_after_paint'
                  };
                  requestAnimationFrame(() => requestAnimationFrame(() => {
                    completeOpen(token, values);
                  }));
                }
                video.requestVideoFrameCallback(onFrame);
              };
              video.requestVideoFrameCallback(onFrame);

              window.__cambarMarkOpen = token => {
                pendingOpen = {token, startedAt: performance.now()};
                video.play().catch(() => {});
              };
            }

            class CamBarVideo extends VideoRTC {
              oninit() {
                super.oninit();
                this.video.controls = false;
                this.video.autoplay = true;
                this.video.muted = true;
                this.video.disablePictureInPicture = true;
                this.video.addEventListener('loadedmetadata', () => emit('loaded_metadata', {
                  detail: JSON.stringify({width: this.video.videoWidth, height: this.video.videoHeight})
                }));
                this.video.addEventListener('playing', () => emit('playing'));
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

            function startStallTimer() {
              if (stallTimer !== null) return;
              lastFrameAt = performance.now();
              stallReported = false;
              stallTimer = setInterval(() => {
                if (sawFirstFrame && !stallReported && performance.now() - lastFrameAt > 2000) {
                  stallReported = true;
                  emit('frame_stalled');
                }
              }, 500);
            }

            function stopStallTimer() {
              if (stallTimer === null) return;
              clearInterval(stallTimer);
              stallTimer = null;
            }

            window.__cambarStop = () => {
              clearInterval(stallTimer);
              pendingOpen = null;
              try { player.ondisconnect(); } catch (_) {}
              try { player.remove(); } catch (_) {}
            };
            window.__cambarSetVisible = visible => {
              if (visible) {
                startStallTimer();
                player.video && player.video.play().catch(() => {});
              } else {
                stopStallTimer();
              }
            };
            window.__cambarResume = () => {
              player.video && player.video.play().catch(() => {});
            };
          </script>
        </body>
        </html>
        """
    }
}
