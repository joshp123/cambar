import CamBarCore
import Foundation

@MainActor
final class Go2RTCRelayController {
    static let mainStreamName = "cambar_main"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case helperMissing
        case sourceMissing
        case configWriteFailed
        case processLaunchFailed(String)
        case processExited(Int32)
        case cameraUnavailable

        var description: String {
            switch self {
            case .helperMissing: "go2rtc helper missing"
            case .sourceMissing: "camera source missing"
            case .configWriteFailed: "relay config write failed"
            case let .processLaunchFailed(message): "go2rtc launch failed: \(message)"
            case let .processExited(status): "go2rtc exited with status \(status)"
            case .cameraUnavailable: "camera unavailable"
            }
        }
    }

    enum State: Equatable {
        case stopped
        case starting(attempt: Int)
        case warming(attempt: Int)
        case ready
        case waitingToRetry(failure: Failure, delay: TimeInterval)
    }

    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            DirectStreamTelemetry.record(component: "relay", event: state.telemetryEvent, detail: state.telemetryDetail)
            onStateChange?(state)
        }
    }

    private let retryPolicy: RelayRetryPolicy
    private var process: Process?
    private var logPipe: Pipe?
    private var logHandle: FileHandle?
    private var recoveryTask: Task<Void, Never>?
    private var generation = 0

    init(retryPolicy: RelayRetryPolicy = RelayRetryPolicy()) {
        self.retryPolicy = retryPolicy
    }

    func start() {
        guard recoveryTask == nil else { return }
        generation += 1
        let currentGeneration = generation
        recoveryTask = Task { [weak self] in
            await self?.runRecoveryLoop(generation: currentGeneration)
        }
    }

    func restart() {
        cancelRecovery()
        terminateProcess()
        start()
    }

    func stop() {
        cancelRecovery()
        terminateProcess()
        state = .stopped
    }

    private var cacheDirectory: URL {
        StreamSourceResolver.makeCacheFolderURL(namespace: "go2rtc")
    }

    private func runRecoveryLoop(generation expectedGeneration: Int) async {
        var attempt = 0
        var failureCount = 0

        while !Task.isCancelled, expectedGeneration == generation {
            attempt += 1
            state = .starting(attempt: attempt)
            terminateProcess()
            if attempt > 1 {
                try? await Task.sleep(for: .milliseconds(150))
            }

            switch startProcess() {
            case .success:
                state = .warming(attempt: attempt)
                if await waitForCurrentVideo(timeout: 8) {
                    guard !Task.isCancelled, expectedGeneration == generation else { return }
                    state = .ready
                    recoveryTask = nil
                    return
                }
            case let .failure(failure):
                await scheduleRetry(after: failure, failureCount: &failureCount)
                continue
            }

            let failure: Failure
            if let process, !process.isRunning {
                failure = .processExited(process.terminationStatus)
            } else {
                failure = .cameraUnavailable
            }
            terminateProcess()
            await scheduleRetry(after: failure, failureCount: &failureCount)
        }
    }

    private func scheduleRetry(after failure: Failure, failureCount: inout Int) async {
        failureCount += 1
        let delay = retryPolicy.delay(afterFailure: failureCount)
        state = .waitingToRetry(failure: failure, delay: delay)
        try? await Task.sleep(for: .seconds(delay))
    }

    private func startProcess() -> Result<Void, Failure> {
        guard let go2rtcPath = StreamSourceResolver.resolveExecutablePath("go2rtc", overridePath: nil) else {
            return .failure(.helperMissing)
        }
        guard let configURL = writeConfig() else {
            return .failure(sourceURL() == nil ? .sourceMissing : .configWriteFailed)
        }

        killLegacyRelay(configURL: configURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: go2rtcPath)
        process.arguments = ["-config", configURL.path]
        process.environment = ["PATH": StreamSourceResolver.searchPaths().joined(separator: ":")]
        attachRedactedLogOutput(to: process)
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            Task { @MainActor [weak self] in
                self?.processDidTerminate(process)
            }
        }

        do {
            try process.run()
            self.process = process
            return .success(())
        } catch {
            closeLogOutput()
            return .failure(.processLaunchFailed(error.localizedDescription))
        }
    }

    private func sourceURL() -> String? {
        StreamSourceResolver.loadRtspOverride()
            ?? StreamSourceResolver.loadCameraConfig(from: StreamSourceResolver.defaultConfigURL())
                .flatMap(StreamSourceResolver.buildRtspURL)
    }

    private func writeConfig() -> URL? {
        guard let primaryRTSPURL = sourceURL() else { return nil }
        let configURL = cacheDirectory.appendingPathComponent("go2rtc.yaml")
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

    private func waitForCurrentVideo(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousSample: RelayStreamSample?

        while !Task.isCancelled, Date() < deadline {
            guard process?.isRunning == true else { return false }
            if let sample = await streamSample() {
                if let previousSample, sample.isAdvancing(from: previousSample) {
                    return true
                }
                previousSample = sample
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func streamSample() async -> RelayStreamSample? {
        guard let encoded = Self.mainStreamName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://127.0.0.1:1984/api/streams?src=\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return RelayStreamSample.decode(data)
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        process = nil
        closeLogOutput()
    }

    private func terminateProcess() {
        guard let process else {
            closeLogOutput()
            return
        }
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        closeLogOutput()
    }

    private func cancelRecovery() {
        generation += 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func killLegacyRelay(configURL: URL) {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "go2rtc.*\(configURL.path)"]
        try? kill.run()
        kill.waitUntilExit()
    }

    private func attachRedactedLogOutput(to process: Process) {
        closeLogOutput()
        let logURL = cacheDirectory.appendingPathComponent("go2rtc.log")
        try? Data().write(to: logURL, options: .atomic)
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }

        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.writeLog(data)
            }
        }
        process.standardOutput = pipe
        process.standardError = pipe
        logHandle = handle
        logPipe = pipe
    }

    private func writeLog(_ data: Data) {
        logHandle?.write(StreamSourceResolver.redactRtspCredentials(in: data))
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

private extension Go2RTCRelayController.State {
    var telemetryEvent: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .warming: "warming"
        case .ready: "ready"
        case .waitingToRetry: "waiting_to_retry"
        }
    }

    var telemetryDetail: String? {
        switch self {
        case .stopped, .ready:
            nil
        case let .starting(attempt), let .warming(attempt):
            "attempt=\(attempt)"
        case let .waitingToRetry(failure, delay):
            "failure=\(failure.description) delay_seconds=\(Int(delay))"
        }
    }
}
