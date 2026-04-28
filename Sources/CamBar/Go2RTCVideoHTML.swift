extension VideoHostView {
    static func stopJavaScript() -> String {
        """
        (function() {
          try {
            for (const pc of window.__cambarPeerConnections || []) {
              try { pc.close(); } catch (_) {}
            }
            for (const video of document.querySelectorAll('video')) {
              try { video.pause(); } catch (_) {}
              try {
                if (video.srcObject) {
                  for (const track of video.srcObject.getTracks()) {
                    try { track.stop(); } catch (_) {}
                  }
                }
              } catch (_) {}
              try { video.removeAttribute('src'); } catch (_) {}
              try { video.srcObject = null; } catch (_) {}
              try { video.load(); } catch (_) {}
            }
            for (const node of document.querySelectorAll('simple-video')) {
              try { node.remove(); } catch (_) {}
            }
          } catch (_) {}
        })();
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
            html, body {
              width: 100%;
              height: 100%;
              margin: 0;
              padding: 0;
              overflow: hidden;
              background: #000;
            }
            simple-video {
              display: block;
              position: relative;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: #000;
              transform: translateZ(0);
              isolation: isolate;
            }
            video {
              position: absolute;
              inset: 0;
              width: 100%;
              height: 100%;
              object-fit: contain;
              background: #000;
              display: block;
              pointer-events: none;
            }
          </style>
        </head>
        <body>
          <script type="module">
            import {VideoRTC} from './video-rtc.js';

            const generation = '\(generation)';
            const streamName = '\(streamName)';
            const startedAt = performance.now();
            window.__cambarPeerConnections = [];

            function emit(name, detail) {
              try {
                window.webkit.messageHandlers.cambarVideoEvent.postMessage({
                  generation,
                  name,
                  stream: streamName,
                  elapsed_ms: Math.round(performance.now() - startedAt),
                  detail: detail || ''
                });
              } catch (_) {}
            }
            window.__cambarPost = (message) => emit(message.name, message.detail);
            function emitVisibility(reason) {
              emit('visibility_state', JSON.stringify({
                reason,
                hidden: document.hidden,
                visibilityState: document.visibilityState,
                hasFocus: document.hasFocus()
              }));
            }
            document.addEventListener('visibilitychange', () => emitVisibility('visibilitychange'));

            const NativeRTCPeerConnection = window.RTCPeerConnection;
            window.RTCPeerConnection = new Proxy(NativeRTCPeerConnection, {
              construct(target, args) {
                const pc = Reflect.construct(target, args);
                window.__cambarPeerConnections.push(pc);
                emit('pc_created');
                pc.addEventListener('connectionstatechange', () => emit('pc_connection_state', JSON.stringify({
                  connectionState: pc.connectionState,
                  iceConnectionState: pc.iceConnectionState,
                  signalingState: pc.signalingState
                })));
                pc.addEventListener('iceconnectionstatechange', () => emit('pc_ice_connection_state', JSON.stringify({
                  connectionState: pc.connectionState,
                  iceConnectionState: pc.iceConnectionState,
                  signalingState: pc.signalingState
                })));
                return pc;
              }
            });

            function videoQuality(video) {
              const quality = video.getVideoPlaybackQuality ? video.getVideoPlaybackQuality() : null;
              return {
                decodedFrames: video.webkitDecodedFrameCount || 0,
                droppedFrames: video.webkitDroppedFrameCount || 0,
                totalVideoFrames: quality ? quality.totalVideoFrames : null,
                droppedVideoFrames: quality ? quality.droppedVideoFrames : null
              };
            }

            function hookFreshness(video) {
              let frameCount = 0;
              const initialQuality = videoQuality(video);
              let revealed = false;
              const maybeFresh = (detail) => {
                if (revealed) return;
                const quality = videoQuality(video);
                const totalDelta = quality.totalVideoFrames != null && initialQuality.totalVideoFrames != null
                  ? quality.totalVideoFrames - initialQuality.totalVideoFrames
                  : 0;
                const decodedDelta = quality.decodedFrames - initialQuality.decodedFrames;
                if (video.videoWidth > 0 && video.videoHeight > 0 && (frameCount >= 1 || totalDelta >= 1 || decodedDelta >= 1)) {
                  revealed = true;
                  emit('fresh_enough', JSON.stringify({ ...detail, frameCount, totalDelta, decodedDelta, ...quality }));
                }
              };

              if (typeof video.requestVideoFrameCallback === 'function') {
                const onFrame = (_now, metadata) => {
                  frameCount += 1;
                  const detail = {
                    readyState: video.readyState,
                    videoWidth: video.videoWidth,
                    videoHeight: video.videoHeight,
                    presentedFrames: metadata.presentedFrames,
                    mediaTime: metadata.mediaTime,
                    presentationTime: metadata.presentationTime,
                    expectedDisplayTime: metadata.expectedDisplayTime,
                    captureTime: metadata.captureTime || null,
                    receiveTime: metadata.receiveTime || null,
                    rtpTimestamp: metadata.rtpTimestamp || null
                  };
                  if (!revealed) {
                    emit('video_frame', JSON.stringify(detail));
                    maybeFresh(detail);
                  }
                  video.requestVideoFrameCallback(onFrame);
                };
                video.requestVideoFrameCallback(onFrame);
              } else {
                const timer = setInterval(() => {
                  const detail = {
                    readyState: video.readyState,
                    videoWidth: video.videoWidth,
                    videoHeight: video.videoHeight
                  };
                  maybeFresh(detail);
                  if (revealed) clearInterval(timer);
                }, 100);
              }
            }

            emit('html_loaded');

            class SimpleVideo extends VideoRTC {
              oninit() {
                this.video = document.createElement('video');
                this.video.controls = false;
                this.video.autoplay = true;
                this.video.muted = true;
                this.video.playsInline = true;
                this.video.preload = 'auto';
                this.video.disablePictureInPicture = true;
                this.video.controlsList = 'nodownload nofullscreen noremoteplayback';
                this.video.addEventListener('loadedmetadata', () => emit('loadedmetadata'));
                this.video.addEventListener('loadeddata', () => emit('loadeddata'));
                this.video.addEventListener('canplay', () => emit('canplay'));
                this.video.addEventListener('playing', () => emit('playing'));
                this.video.addEventListener('waiting', () => emit('waiting'));
                this.video.addEventListener('stalled', () => emit('stalled'));
                this.video.addEventListener('error', () => emit('error', this.video.error ? this.video.error.message : 'video error'));
                hookFreshness(this.video);
                this.appendChild(this.video);
              }

              onconnect() {
                emitVisibility('onconnect');
                return super.onconnect();
              }

              ondisconnect() {
                emit('video_rtc_disconnect');
                return super.ondisconnect();
              }

              onclose() {
                emit('video_rtc_close');
                return super.onclose();
              }

              onwebrtc() {
                const pc = new RTCPeerConnection(this.pcConfig);
                let attached = false;

                pc.addEventListener('icecandidate', ev => {
                  if (ev.candidate && this.mode.includes('webrtc/tcp') && ev.candidate.protocol === 'udp') return;
                  const candidate = ev.candidate ? ev.candidate.toJSON().candidate : '';
                  this.send({type: 'webrtc/candidate', value: candidate});
                });

                pc.addEventListener('connectionstatechange', () => {
                  if (pc.connectionState === 'connected') {
                    if (!attached) {
                      const tracks = pc.getTransceivers()
                        .filter(tr => tr.currentDirection === 'recvonly')
                        .map(tr => tr.receiver.track);
                      this.video.srcObject = new MediaStream(tracks);
                      this.play();
                      this.pcState = WebSocket.OPEN;
                      this.wsState = WebSocket.CLOSED;
                      if (this.ws) {
                        this.ws.close();
                        this.ws = null;
                      }
                      attached = true;
                      emit('pc_video_attached', JSON.stringify({ tracks: tracks.length }));
                    }
                  } else if (pc.connectionState === 'failed' || pc.connectionState === 'disconnected') {
                    pc.close();
                    this.pcState = WebSocket.CLOSED;
                    this.pc = null;
                    this.onconnect();
                  }
                });

                this.onmessage['webrtc'] = msg => {
                  switch (msg.type) {
                    case 'webrtc/candidate':
                      if (this.mode.includes('webrtc/tcp') && msg.value.includes(' udp ')) return;
                      pc.addIceCandidate({candidate: msg.value, sdpMid: '0'}).catch(error => emit('webrtc_candidate_error', String(error && error.message ? error.message : error)));
                      break;
                    case 'webrtc/answer':
                      pc.setRemoteDescription({type: 'answer', sdp: msg.value}).catch(error => emit('webrtc_answer_error', String(error && error.message ? error.message : error)));
                      break;
                    case 'error':
                      if (!msg.value.includes('webrtc/offer')) return;
                      pc.close();
                      break;
                  }
                };

                this.createOffer(pc).then(offer => {
                  this.send({type: 'webrtc/offer', value: offer.sdp});
                });

                this.pcState = WebSocket.CONNECTING;
                this.pc = pc;
              }
            }

            customElements.define('simple-video', SimpleVideo);
            const video = document.createElement('simple-video');
            video.mode = 'webrtc';
            video.media = 'video';
            video.background = false;
            video.visibilityCheck = false;
            video.src = new URL('api/ws?src=' + encodeURIComponent(streamName) + '&cambarGen=' + encodeURIComponent(generation), location.href);
            document.body.appendChild(video);
            emit('element_attached');
            emitVisibility('attached');
          </script>
        </body>
        </html>
        """
    }
}
