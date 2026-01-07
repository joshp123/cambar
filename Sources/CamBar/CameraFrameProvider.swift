import AVFoundation
import AVKit
import AppKit
import Foundation

// GCD serializes streaming work; UI updates are dispatched onto the main queue.
final class CameraFrameProvider: ObservableObject, @unchecked Sendable {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var cameraName: String
    @Published private(set) var camsnapPath: String?
    @Published private(set) var ffmpegPath: String?
    @Published private(set) var streamURL: URL?

    private let configURL: URL
    private let hlsFolderURL: URL
    private let playlistURL: URL
    private var config: CamBarConfig
    private var cameraConfig: CameraConfig?
    private let workerQueue = DispatchQueue(label: "CamBar.stream.worker")
    private var ffmpegProcess: Process?
    private var readinessTimer: DispatchSourceTimer?
    private var isStarting = false
    private let server: HLSServer
    private var playerItemObservation: NSKeyValueObservation?
    private var playbackTimer: DispatchSourceTimer?
    private var lastPlaybackSeconds: Double?
    private var stallTicks = 0

    init(autoStart: Bool = true) {
        self.configURL = Self.defaultConfigURL()
        self.hlsFolderURL = Self.makeHLSFolderURL()
        self.playlistURL = hlsFolderURL.appendingPathComponent("master.m3u8")
        self.config = Self.loadConfig()
        self.cameraName = Self.loadCameraName(from: configURL) ?? "hikvision"
        self.camsnapPath = Self.resolveExecutablePath("camsnap", overridePath: config.camsnapPath)
        self.ffmpegPath = Self.resolveExecutablePath("ffmpeg", overridePath: config.ffmpegPath)
        self.cameraConfig = Self.loadCameraConfig(from: configURL)
        let serverFile = hlsFolderURL.appendingPathComponent("server.txt")
        self.server = HLSServer(root: hlsFolderURL, onReady: { url in
            try? Data(url.absoluteString.utf8).write(to: serverFile, options: .atomic)
        })
        if autoStart {
            start()
        }
    }

    deinit {
        stopStream()
    }

    func reload() {
        restartStream()
    }

    func stop() {
        stopStream()
    }

    func startStreaming() {
        workerQueue.async { [weak self] in
            self?.start()
        }
    }

    static func openConfig() {
        let url = defaultConfigURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openCacheFolder() {
        let folder = makeHLSFolderURL()
        NSWorkspace.shared.open(folder)
    }

    private func start() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            publishError("Missing camsnap config at \(configURL.path).")
            return
        }
        guard let cameraConfig else {
            publishError("No cameras found in camsnap config.")
            return
        }
        guard let ffmpegPath else {
            publishError("ffmpeg not found. Use local nix build or set FFMPEG_PATH.")
            return
        }
        guard let rtspURL = Self.buildRtspURL(from: cameraConfig) else {
            publishError("Unable to build RTSP URL from camsnap config.")
            return
        }
        clearHLSFolder()
        server.start()
        startStream(ffmpegPath: ffmpegPath, rtspURL: rtspURL, transport: cameraConfig.rtspTransport)
    }

    private func restartStream() {
        workerQueue.async { [weak self] in
            self?.stopStreamInternal()
            Thread.sleep(forTimeInterval: 0.3)
            self?.start()
        }
    }

    private func stopStream() {
        workerQueue.async { [weak self] in
            self?.stopStreamInternal()
        }
    }

    private func stopStreamInternal() {
        readinessTimer?.cancel()
        readinessTimer = nil
        if let process = ffmpegProcess {
            process.terminate()
            process.waitUntilExit()
        }
        ffmpegProcess = nil
        server.stop()
        DispatchQueue.main.async {
            self.player = nil
            self.streamURL = nil
            self.playerItemObservation = nil
            self.playbackTimer?.cancel()
            self.playbackTimer = nil
            self.lastPlaybackSeconds = nil
            self.stallTicks = 0
        }
    }

    private func startStream(ffmpegPath: String, rtspURL: String, transport: String?) {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        killLegacyFfmpeg()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        var args: [String] = ["-hide_banner", "-loglevel", "info"]
        if let transport {
            args += ["-rtsp_transport", transport]
        } else {
            args += ["-rtsp_transport", "tcp"]
        }
        args += [
            "-fflags", "nobuffer",
            "-flags", "low_delay",
            "-i", rtspURL,
            "-an",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-tune", "zerolatency",
            "-pix_fmt", "yuv420p",
            "-g", "25",
            "-keyint_min", "25",
            "-sc_threshold", "0",
            "-f", "hls",
            "-hls_time", "1",
            "-hls_list_size", "12",
            "-hls_flags", "append_list+omit_endlist+independent_segments",
            "-hls_segment_filename", hlsFolderURL.appendingPathComponent("segment-%03d.ts").path,
            playlistURL.path
        ]

        process.arguments = args
        process.environment = buildEnvironment()

        let logURL = hlsFolderURL.appendingPathComponent("ffmpeg.log")
        let rtspURLFile = hlsFolderURL.appendingPathComponent("rtsp.txt")
        let debugURL = hlsFolderURL.appendingPathComponent("debug.txt")
        let debug = [
            "camera=\(cameraName)",
            "ffmpeg=\(ffmpegPath)",
            "rtsp=\(rtspURL)"
        ].joined(separator: "\n")
        try? Data(debug.utf8).write(to: debugURL, options: .atomic)
        try? Data(rtspURL.utf8).write(to: rtspURLFile, options: .atomic)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            if proc.terminationStatus != 0 {
                self.publishError("ffmpeg exited with code \(proc.terminationStatus).")
            }
        }

        do {
            try process.run()
            ffmpegProcess = process
        } catch {
            let message = "Failed to start ffmpeg: \(error.localizedDescription)\n"
            if let data = message.data(using: .utf8) {
                try? data.write(to: logURL, options: .atomic)
            }
            publishError("Failed to start ffmpeg: \(error.localizedDescription)")
            return
        }

        waitForPlaylist()
    }

    private func killLegacyFfmpeg() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", hlsFolderURL.appendingPathComponent("master.m3u8").path]
        try? kill.run()
        kill.waitUntilExit()
    }

    private func clearHLSFolder() {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: hlsFolderURL.path) else {
            return
        }
        for name in contents {
            let url = hlsFolderURL.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func waitForPlaylist() {
        var attempts = 0
        let timer = DispatchSource.makeTimerSource(queue: workerQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1
            guard let baseURL = self.server.baseURL else {
                if attempts > 50 {
                    self.publishError("Local HLS server not ready.")
                    self.readinessTimer?.cancel()
                    self.readinessTimer = nil
                }
                return
            }
            if let data = try? Data(contentsOf: self.playlistURL), !data.isEmpty {
                self.readinessTimer?.cancel()
                self.readinessTimer = nil
                let url = baseURL.appendingPathComponent("master.m3u8")
                DispatchQueue.main.async {
                    let player = self.player ?? AVPlayer()
                    self.configure(player: player, url: url)
                    player.playImmediately(atRate: 1.0)
                    self.player = player
                    self.streamURL = url
                    self.errorMessage = nil
                    self.lastUpdated = Date()
                    self.startPlaybackWatchdog()
                }
                return
            }
            if attempts > 50 {
                self.readinessTimer?.cancel()
                self.readinessTimer = nil
                self.publishError("Stream did not start. Check RTSP credentials or camera reachability.")
            }
        }
        timer.resume()
        readinessTimer = timer
    }

    private func startPlaybackWatchdog() {
        playbackTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self,
                  let player = self.player,
                  let item = player.currentItem else { return }
            let ranges = item.seekableTimeRanges
            if let range = ranges.last?.timeRangeValue {
                let live = CMTimeRangeGetEnd(range)
                let current = player.currentTime()
                if live.isNumeric && current.isNumeric {
                    let lag = CMTimeSubtract(live, current)
                    if lag.seconds > 1.5 {
                        item.seek(to: live, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            player.play()
                        }
                        return
                    }
                }
            }
            if let seconds = player.currentTime().seconds as Double? {
                if let last = self.lastPlaybackSeconds, abs(seconds - last) < 0.05 {
                    self.stallTicks += 1
                } else {
                    self.stallTicks = 0
                }
                self.lastPlaybackSeconds = seconds
                if self.stallTicks >= 3, let url = self.streamURL {
                    self.configure(player: player, url: url)
                    player.playImmediately(atRate: 1.0)
                    self.stallTicks = 0
                    return
                }
            }
            if player.timeControlStatus != .playing {
                player.play()
            }
        }
        timer.resume()
        playbackTimer = timer
    }

    private func configure(player: AVPlayer, url: URL) {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0.1
        playerItemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            guard let self else { return }
            if observed.status == .failed {
                let detail = observed.error?.localizedDescription ?? "unknown error"
                self.publishError("Playback failed: \(detail)")
            }
        }
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none
        player.isMuted = true
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
        }
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.searchPaths().joined(separator: ":")
        return env
    }

    private static func resolveExecutablePath(_ name: String, overridePath: String?) -> String? {
        if let overridePath {
            let expanded = (overridePath as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        let envVar = name.uppercased() + "_PATH"
        if let envPath = ProcessInfo.processInfo.environment[envVar],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }
        for dir in searchPaths() {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func defaultConfigURL() -> URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".config/camsnap/config.yaml"))
    }

    private static func searchPaths() -> [String] {
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
            (NSHomeDirectory() as NSString).appendingPathComponent(".nix-profile/bin"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
            "/usr/bin",
            "/bin"
        ]
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        var seen = Set<String>()
        var result: [String] = []
        for path in extraPaths + inherited {
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            result.append(path)
        }
        return result
    }

    private struct CamBarConfig: Codable {
        var camsnapPath: String?
        var ffmpegPath: String?
    }

    private static func configFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("CamBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("config.json")
    }

    private static func loadConfig() -> CamBarConfig {
        let url = configFileURL()
        guard let data = try? Data(contentsOf: url) else {
            return CamBarConfig()
        }
        return (try? JSONDecoder().decode(CamBarConfig.self, from: data)) ?? CamBarConfig()
    }

    private static func loadCameraName(from url: URL) -> String? {
        return loadCameraConfig(from: url)?.name
    }

    private struct CameraConfig {
        var name: String?
        var host: String?
        var port: Int?
        var protocolName: String?
        var username: String?
        var password: String?
        var rtspTransport: String?
        var stream: String?
    }

    private static func loadCameraConfig(from url: URL) -> CameraConfig? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var current = CameraConfig()
        var hasCamera = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- name:") {
                if hasCamera {
                    break
                }
                hasCamera = true
                current.name = line.replacingOccurrences(of: "- name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let rawValue = parts[1].trimmingCharacters(in: .whitespaces)
            let value = stripQuotes(rawValue)
            switch key {
            case "host": current.host = value
            case "port": current.port = Int(value)
            case "protocol": current.protocolName = value
            case "username": current.username = value
            case "password": current.password = value
            case "rtsp_transport": current.rtspTransport = value
            case "stream": current.stream = value
            default: break
            }
        }
        return hasCamera ? current : nil
    }

    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func buildRtspURL(from camera: CameraConfig) -> String? {
        if let override = ProcessInfo.processInfo.environment["CAMBAR_RTSP_URL"], !override.isEmpty {
            return override
        }
        if let stream = camera.stream, stream.contains("://") {
            return stream
        }
        guard let host = camera.host else { return nil }
        let scheme = camera.protocolName ?? "rtsp"
        let port = camera.port ?? 554
        var userInfo = ""
        if let username = camera.username {
            let user = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            if let password = camera.password {
                let pass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                userInfo = "\(user):\(pass)@"
            } else {
                userInfo = "\(user)@"
            }
        }
        let streamPath = camera.stream ?? "Streaming/Channels/101"
        let path = streamPath.hasPrefix("/") ? streamPath : "/\(streamPath)"
        return "\(scheme)://\(userInfo)\(host):\(port)\(path)"
    }

    private static func makeHLSFolderURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = caches.appendingPathComponent("CamBar", isDirectory: true)
            .appendingPathComponent("hls", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
