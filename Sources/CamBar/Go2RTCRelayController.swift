import CamBarCore
import Foundation

final class Go2RTCRelayController: @unchecked Sendable {
    static let mainStreamName = "cambar_main"

    private let queue = DispatchQueue(label: "CamBar.go2rtc")
    private var process: Process?
    private var logPipe: Pipe?
    private var logHandle: FileHandle?

    private var cacheDirectory: URL {
        StreamSourceResolver.makeCacheFolderURL(namespace: "go2rtc")
    }

    func startIfAvailable() -> Bool {
        queue.sync {
            if process != nil { return true }
            return startLocked(event: "start_requested")
        }
    }

    func stop() {
        queue.sync {
            stopLocked()
        }
    }

    func waitForMainReady(timeout: TimeInterval = 15, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            let deadline = Date().addingTimeInterval(timeout)
            var mainReady = false
            while Date() < deadline {
                if !mainReady, self.streamHasVideo(Self.mainStreamName) {
                    mainReady = true
                    DirectStreamTelemetry.record(component: "relay", event: "stream_warm", stream: Self.mainStreamName)
                }
                if mainReady {
                    completion(true)
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DirectStreamTelemetry.record(
                component: "relay",
                event: "stream_warm_timeout",
                detail: "main=\(mainReady)"
            )
            completion(false)
        }
    }

    private func writeConfig() -> URL? {
        let configURL = cacheDirectory.appendingPathComponent("go2rtc.yaml")
        let primaryRTSPURL = StreamSourceResolver.loadRtspOverride()
            ?? StreamSourceResolver.loadCameraConfig(from: StreamSourceResolver.defaultConfigURL())
                .flatMap { StreamSourceResolver.buildRtspURL(from: $0) }
        guard let primaryRTSPURL else { return nil }

        let config = """
        api:
          listen: 127.0.0.1:1984
        rtsp:
          listen: 127.0.0.1:8554
        webrtc:
          listen: 127.0.0.1:8555
        streams:
          cambar_main:
            - \(primaryRTSPURL)#backchannel=0
        preload:
          cambar_main: video
        """
        do {
            try Data(config.utf8).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return configURL
        } catch {
            return nil
        }
    }

    private func startLocked(event: String) -> Bool {
        DirectStreamTelemetry.record(component: "relay", event: event)
        guard let go2rtcPath = StreamSourceResolver.resolveExecutablePath("go2rtc", overridePath: nil) else {
            DirectStreamTelemetry.record(component: "relay", event: "go2rtc_not_found")
            return false
        }
        guard let configURL = writeConfig() else {
            DirectStreamTelemetry.record(component: "relay", event: "config_write_failed")
            return false
        }
        killLegacyRelay(configURL: configURL)
        return startProcess(go2rtcPath: go2rtcPath, configURL: configURL)
    }

    private func startProcess(go2rtcPath: String, configURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: go2rtcPath)
        process.arguments = ["-config", configURL.path]
        process.environment = [
            "PATH": StreamSourceResolver.searchPaths().joined(separator: ":")
        ]
        attachRedactedLogOutput(to: process)
        process.terminationHandler = { [weak self] _ in
            guard let relay = self else { return }
            relay.queue.async {
                DirectStreamTelemetry.record(
                    component: "relay",
                    event: "process_terminated",
                    detail: "status=\(process.terminationStatus)"
                )
                guard relay.process === process else { return }
                relay.closeLogOutput()
                relay.process = nil
            }
        }
        do {
            try process.run()
            self.process = process
            DirectStreamTelemetry.record(component: "relay", event: "process_started")
            return true
        } catch {
            closeLogOutput()
            DirectStreamTelemetry.record(component: "relay", event: "process_start_failed", detail: error.localizedDescription)
            return false
        }
    }

    private func killLegacyRelay(configURL: URL) {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "go2rtc.*\(configURL.path)"]
        try? kill.run()
        kill.waitUntilExit()
    }

    private func stopLocked() {
        if let process {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        closeLogOutput()
    }

    private func streamHasVideo(_ streamName: String) -> Bool {
        guard let encoded = streamName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://127.0.0.1:1984/api/streams?src=\(encoded)") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        guard let data = try? URLSession.shared.synchronousData(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let producers = json["producers"] as? [[String: Any]] else {
            return false
        }
        return producers.contains { producer in
            guard let bytes = producer["bytes_recv"] as? Int else { return false }
            return bytes > 300_000
        }
    }

    private func attachRedactedLogOutput(to process: Process) {
        closeLogOutput()
        let logURL = cacheDirectory.appendingPathComponent("go2rtc.log")
        try? Data().write(to: logURL, options: .atomic)
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            return
        }
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            self?.logHandle?.write(StreamSourceResolver.redactRtspCredentials(in: data))
        }
        process.standardOutput = pipe
        process.standardError = pipe
        logHandle = handle
        logPipe = pipe
    }

    private func closeLogOutput() {
        logPipe?.fileHandleForReading.readabilityHandler = nil
        try? logPipe?.fileHandleForReading.close()
        logPipe = nil
        if let logHandle {
            try? logHandle.close()
            self.logHandle = nil
        }
    }
}

private extension URLSession {
    func synchronousData(for request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = URLSessionResultBox()
        let task = dataTask(with: request) { data, _, error in
            if let error {
                box.set(.failure(error))
            } else {
                box.set(.success(data ?? Data()))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try box.value()?.get() ?? Data()
    }
}

private final class URLSessionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, Error>?

    func set(_ value: Result<Data, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func value() -> Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
