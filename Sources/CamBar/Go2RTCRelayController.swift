import CamBarCore
import Darwin
import Foundation
import Network

@MainActor
final class Go2RTCRelayController {
    static let mainStreamName = "cambar_main"

    enum Failure: Error, Equatable, CustomStringConvertible {
        case helperMissing
        case sourceMissing
        case configWriteFailed
        case processLaunchFailed(String)
        case processExited(Int32)
        case cameraRouteUnavailable
        case cameraUnavailable

        var description: String {
            switch self {
            case .helperMissing: "go2rtc helper missing"
            case .sourceMissing: "camera source missing"
            case .configWriteFailed: "relay config write failed"
            case let .processLaunchFailed(message): "go2rtc launch failed: \(message)"
            case let .processExited(status): "go2rtc exited with status \(status)"
            case .cameraRouteUnavailable: "camera route unavailable"
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
    private var cleanedUpLegacyRelay = false
    private var preparedDiagnosticLog = false
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["CAMBAR_DIAGNOSTICS"] == "1"
    private let healthSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

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
        generation += 1
        let currentGeneration = generation
        let previousRecovery = recoveryTask
        previousRecovery?.cancel()
        recoveryTask = Task { [weak self] in
            await previousRecovery?.value
            guard !Task.isCancelled else { return }
            await self?.runRecoveryLoop(generation: currentGeneration)
        }
    }

    func stop() {
        cancelRecovery()
        terminateProcessForShutdown()
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
            await terminateProcess()
            if attempt > 1 {
                try? await Task.sleep(for: .milliseconds(150))
            }

            guard await waitForCameraRoute() else {
                await scheduleRetry(after: .cameraRouteUnavailable, failureCount: &failureCount)
                continue
            }

            switch startProcess() {
            case .success:
                state = .warming(attempt: attempt)
                if await waitForCurrentVideo(timeout: 8) {
                    guard !Task.isCancelled, expectedGeneration == generation else { return }
                    state = .ready
                    failureCount = 0
                    let failure = await waitForRuntimeFailure(generation: expectedGeneration)
                    guard !Task.isCancelled, expectedGeneration == generation else { return }
                    await terminateProcess()
                    await scheduleRetry(after: failure, failureCount: &failureCount)
                    continue
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
            await terminateProcess()
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
        guard let go2rtcPath = StreamSourceResolver.bundledGo2RTCPath() else {
            return .failure(.helperMissing)
        }
        let configURL: URL
        switch writeConfig() {
        case let .success(url):
            configURL = url
        case let .failure(failure):
            return .failure(failure)
        }

        cleanUpLegacyRelayIfNeeded(configURL: configURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: go2rtcPath)
        process.arguments = ["-config", configURL.path]
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

    private func waitForCameraRoute(timeout: Duration = .seconds(2)) async -> Bool {
        guard let sourceURL = sourceURL(),
              let components = URLComponents(string: sourceURL),
              let host = components.host,
              let port = UInt16(exactly: components.port ?? 554) else {
            return false
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if await Self.canConnect(host: host, port: port, timeout: .milliseconds(300)) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while !Task.isCancelled && clock.now < deadline
        return false
    }

    private nonisolated static func canConnect(host: String, port: UInt16, timeout: Duration) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.stateUpdateHandler = nil
                            continuation.resume(returning: true)
                        case .failed, .cancelled:
                            connection.stateUpdateHandler = nil
                            continuation.resume(returning: false)
                        default:
                            break
                        }
                    }
                    connection.start(queue: DispatchQueue.global(qos: .userInitiated))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let result = await group.next() ?? false
            connection.cancel()
            group.cancelAll()
            return result
        }
    }

    private func writeConfig() -> Result<URL, Failure> {
        guard let primaryRTSPURL = sourceURL() else { return .failure(.sourceMissing) }
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
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try Data(config.utf8).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            return .success(configURL)
        } catch {
            return .failure(.configWriteFailed)
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
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 0.5
        guard let (data, response) = try? await healthSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return RelayStreamSample.decode(data)
    }

    private func waitForRuntimeFailure(generation expectedGeneration: Int) async -> Failure {
        guard let runningProcess = process else { return .cameraUnavailable }
        var liveness = RelayRuntimeLiveness()

        while !Task.isCancelled, expectedGeneration == generation {
            guard runningProcess.isRunning else { return .processExited(runningProcess.terminationStatus) }
            if liveness.observesFailure(await streamSample()) {
                return .cameraUnavailable
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return .cameraUnavailable
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        process = nil
        closeLogOutput()
    }

    private func terminateProcess() async {
        guard let process = beginProcessTermination() else { return }
        for _ in 0..<20 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        finishProcessTermination(process)
    }

    private func terminateProcessForShutdown() {
        guard let process = beginProcessTermination() else { return }
        for _ in 0..<20 where process.isRunning {
            usleep(10_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        finishProcessTermination(process)
    }

    private func beginProcessTermination() -> Process? {
        guard let process else {
            closeLogOutput()
            return nil
        }
        process.terminationHandler = nil
        closeLogOutput()
        if process.isRunning {
            process.terminate()
        }
        return process
    }

    private func finishProcessTermination(_ terminatedProcess: Process) {
        if process === terminatedProcess {
            process = nil
        }
    }

    private func cancelRecovery() {
        generation += 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func cleanUpLegacyRelayIfNeeded(configURL: URL) {
        guard !cleanedUpLegacyRelay else { return }
        cleanedUpLegacyRelay = true
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "go2rtc.*\(configURL.path)"]
        try? kill.run()
        kill.waitUntilExit()
    }

    private func attachRedactedLogOutput(to process: Process) {
        closeLogOutput()
        guard diagnosticsEnabled else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return
        }
        let logURL = cacheDirectory.appendingPathComponent("go2rtc.log")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if !preparedDiagnosticLog {
            try? Data().write(to: logURL, options: .atomic)
            preparedDiagnosticLog = true
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        handle.seekToEndOfFile()

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
