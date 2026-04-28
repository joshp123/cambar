import AppKit
import CamBarCore
import SwiftUI
import WebKit

struct Go2RTCVideoView: NSViewRepresentable {
    let surface: String

    init(surface: String) {
        self.surface = surface
    }

    static func prewarmAll() {
        Go2RTCWebViewPool.shared.prewarm(surface: "menu")
        Go2RTCWebViewPool.shared.prewarm(surface: "window")
    }

    static func keepWarm(surface: String) {
        Go2RTCWebViewPool.shared.keepWarm(surface: surface)
    }

    static func show(surface: String, frame: NSRect) {
        Go2RTCWebViewPool.shared.show(surface: surface, frame: frame)
    }

    static func hide(surface: String) {
        Go2RTCWebViewPool.shared.hide(surface: surface)
    }

    static func isShowing(surface: String) -> Bool {
        Go2RTCWebViewPool.shared.isShowing(surface: surface)
    }

    static func applyClipPath(surface: String, svgPath: String) {
        Go2RTCWebViewPool.shared.applyClipPath(surface: surface, svgPath: svgPath)
    }

    func makeNSView(context: Context) -> WKWebView {
        Go2RTCWebViewPool.shared.webView(surface: surface)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
private final class Go2RTCWebViewPool {
    static let shared = Go2RTCWebViewPool()
    private static let warmSurfaceSize = NSSize(width: 2688, height: 1520)

    private var entries: [String: Entry] = [:]

    func prewarm(surface: String) {
        _ = webView(surface: surface)
    }

    func keepWarm(surface: String) {
        guard let entry = entries[surface] else { return }
        hideWarmWindow(entry.warmWindow)
        entry.telemetry.record("view_returned_to_warm_window")
    }

    func show(surface: String, frame: NSRect) {
        let webView = webView(surface: surface)
        guard let entry = entries[surface] else { return }
        webView.frame = NSRect(origin: .zero, size: frame.size)
        entry.warmWindow.setFrame(frame, display: true)
        entry.warmWindow.level = .popUpMenu
        entry.warmWindow.orderFrontRegardless()
        entry.telemetry.record("window_shown")
        webView.evaluateJavaScript("document.querySelector('video')?.play()")
    }

    func hide(surface: String) {
        guard let entry = entries[surface] else { return }
        hideWarmWindow(entry.warmWindow)
        entry.telemetry.record("window_hidden")
    }

    func isShowing(surface: String) -> Bool {
        guard let entry = entries[surface] else { return false }
        return entry.warmWindow.frame.origin.x > -1000
    }

    func applyClipPath(surface: String, svgPath: String) {
        guard let entry = entries[surface] else { return }
        let escaped = svgPath.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
          const path = '\(escaped)';
          let style = document.getElementById('cambar-clip-style');
          if (!style) {
            style = document.createElement('style');
            style.id = 'cambar-clip-style';
            document.head.appendChild(style);
          }
          style.textContent = `simple-video, video { clip-path: path('${path}'); border-radius: 0 !important; }`;
        })();
        """
        entry.webView.evaluateJavaScript(js)
    }

    func webView(surface: String) -> WKWebView {
        if let entry = entries[surface] {
            entry.telemetry.record("view_attached")
            return entry.webView
        }

        let telemetry = VideoTelemetry(surface: surface)
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(telemetry, name: "cambarVideoEvent")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = telemetry
        let warmWindow = makeWarmWindow(for: webView)

        let entry = Entry(webView: webView, telemetry: telemetry, warmWindow: warmWindow)
        entries[surface] = entry
        telemetry.record("view_created")
        webView.loadHTMLString(Self.html(), baseURL: URL(string: "http://127.0.0.1:1984/"))
        return webView
    }

    private func makeWarmWindow(for webView: WKWebView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: -10_000,
                y: -10_000,
                width: Self.warmSurfaceSize.width,
                height: Self.warmSurfaceSize.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .normal
        window.backgroundColor = .black
        window.isOpaque = true
        window.alphaValue = 1
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.contentView = webView
        return window
    }

    private func hideWarmWindow(_ window: NSWindow) {
        window.level = .normal
        window.setFrame(
            NSRect(
                x: -10_000,
                y: -10_000,
                width: Self.warmSurfaceSize.width,
                height: Self.warmSurfaceSize.height
            ),
            display: false
        )
        window.orderOut(nil)
    }

    private static func html() -> String {
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
              background: transparent;
            }
            simple-video {
              display: block;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: transparent;
              transform: translateZ(0);
              isolation: isolate;
            }
            video {
              width: 100%;
              height: 100%;
              object-fit: contain;
              background: #000;
              display: block;
            }
          </style>
        </head>
        <body>
          <script type="module">
            import {VideoRTC} from './video-rtc.js';

            const streamName = '\(streamName)';
            const startedAt = performance.now();
            function emit(name, detail) {
              try {
                window.webkit.messageHandlers.cambarVideoEvent.postMessage({
                  name,
                  stream: streamName,
                  elapsed_ms: Math.round(performance.now() - startedAt),
                  detail: detail || ''
                });
              } catch (_) {}
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
                this.video.addEventListener('loadeddata', () => emit('loadeddata'));
                this.video.addEventListener('playing', () => emit('playing'));
                this.video.addEventListener('waiting', () => emit('waiting'));
                this.video.addEventListener('error', () => emit('error', this.video.error ? this.video.error.message : 'video error'));
                this.appendChild(this.video);
              }
            }

            customElements.define('simple-video', SimpleVideo);
            const video = document.createElement('simple-video');
            video.mode = 'webrtc,mse';
            video.media = 'video';
            video.background = true;
            video.src = new URL('api/ws?src=' + encodeURIComponent(streamName), location.href);
            document.body.appendChild(video);
            emit('element_attached');
          </script>
        </body>
        </html>
        """
    }

    private struct Entry {
        let webView: WKWebView
        let telemetry: VideoTelemetry
        let warmWindow: NSWindow
    }
}

private final class VideoTelemetry: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let surface: String
    private let startedAt = ProcessInfo.processInfo.systemUptime

    init(surface: String) {
        self.surface = surface
    }

    func record(_ event: String, elapsedMilliseconds: Int? = nil, detail: String? = nil) {
        DirectStreamTelemetry.record(
            component: "direct-video",
            event: event,
            stream: Go2RTCRelayController.mainStreamName,
            surface: surface,
            elapsedMilliseconds: elapsedMilliseconds ?? Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000),
            detail: detail
        )
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "cambarVideoEvent",
              let body = message.body as? [String: Any],
              let event = body["name"] as? String else {
            return
        }
        record(
            event,
            elapsedMilliseconds: body["elapsed_ms"] as? Int,
            detail: body["detail"] as? String
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        record("navigation_finished")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        record("navigation_failed", detail: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        record("provisional_navigation_failed", detail: error.localizedDescription)
    }
}
