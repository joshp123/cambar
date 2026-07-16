import CamBarCore
import CoreMedia
import CoreVideo
import Foundation
import IPCamKit

struct CameraFrame: @unchecked Sendable {
    let generation: String
    let sequence: UInt64
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
    let decodedAt: TimeInterval

    var size: CGSize {
        CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }
}

private enum CameraStreamEvent: @unchecked Sendable {
    case state(generation: String?, CameraStreamController.State)
    case frameAvailable
}

private final class CameraStreamEventBridge: @unchecked Sendable {
    let stream: AsyncStream<CameraStreamEvent>
    private let continuation: AsyncStream<CameraStreamEvent>.Continuation
    private let lock = NSLock()
    private var latestFrame: CameraFrame?
    private var frameSignalPending = false

    init() {
        var continuation: AsyncStream<CameraStreamEvent>.Continuation!
        stream = AsyncStream(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        self.continuation = continuation
    }

    func yield(_ event: CameraStreamEvent) {
        continuation.yield(event)
    }

    func yield(frame: CameraFrame) {
        lock.lock()
        latestFrame = frame
        let shouldSignal = !frameSignalPending
        frameSignalPending = true
        lock.unlock()
        if shouldSignal {
            continuation.yield(.frameAvailable)
        }
    }

    func takeLatestFrame() -> CameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = latestFrame
        latestFrame = nil
        frameSignalPending = false
        return frame
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
final class CameraStreamController {
    enum State: Equatable, Sendable {
        case stopped
        case connecting
        case ready
        case waitingToRetry(delay: TimeInterval)
        case suspended
    }

    struct ObservationToken: Hashable {
        fileprivate let id: UUID
    }

    var onStateChange: ((State) -> Void)?
    var onVideoSizeChange: ((CGSize) -> Void)?
    private(set) var state: State = .stopped
    private(set) var latestFrame: CameraFrame?
    private(set) var videoSize: CGSize?

    var latestSequence: UInt64 {
        latestFrame?.sequence ?? 0
    }

    private var worker: CameraStreamWorker!
    private let eventBridge: CameraStreamEventBridge
    private var eventTask: Task<Void, Never>?
    private var supervisorTask: Task<Void, Never>?
    private var observers: [UUID: Observer] = [:]
    private var isPermanentlyStopped = false
    private var lifecycleCommandID: UInt64 = 0
    private var activeGeneration: String?

    init(sourceURL: String) {
        let eventBridge = CameraStreamEventBridge()
        self.eventBridge = eventBridge
        worker = CameraStreamWorker(
            sourceURL: sourceURL,
            onState: { eventBridge.yield($0) },
            onFrame: { eventBridge.yield(frame: $0) }
        )
        eventTask = Task { @MainActor [weak self, stream = eventBridge.stream] in
            for await event in stream {
                guard let self else { return }
                self.receive(event: event)
            }
        }
    }

    func start() {
        guard !isPermanentlyStopped else { return }
        lifecycleCommandID &+= 1
        let commandID = lifecycleCommandID
        if supervisorTask != nil {
            Task { await worker.setDesiredRunning(true, commandID: commandID) }
            return
        }
        let worker = worker!
        supervisorTask = Task { [weak self] in
            await worker.run(commandID: commandID)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.supervisorTask = nil
            }
        }
    }

    func retryNow() {
        guard !isPermanentlyStopped else { return }
        lifecycleCommandID &+= 1
        let commandID = lifecycleCommandID
        if supervisorTask == nil {
            start()
        } else {
            Task { await worker.retryNow(commandID: commandID) }
        }
    }

    func suspendForSleep() {
        latestFrame = nil
        videoSize = nil
        notifyFrameCleared()
        lifecycleCommandID &+= 1
        let commandID = lifecycleCommandID
        Task { await worker.setDesiredRunning(false, commandID: commandID) }
    }

    func resumeAfterWake() {
        guard !isPermanentlyStopped else { return }
        start()
    }

    func shutdown() {
        guard !isPermanentlyStopped else { return }
        isPermanentlyStopped = true
        latestFrame = nil
        videoSize = nil
        notifyFrameCleared()
        let task = supervisorTask
        supervisorTask = nil
        task?.cancel()
        eventTask?.cancel()
        eventTask = nil
        eventBridge.finish()
        Task { await worker.shutdown() }
    }

    func addObserver(
        onFrame: @escaping (CameraFrame?) -> Void,
        onState: @escaping (State) -> Void
    ) -> ObservationToken {
        let token = ObservationToken(id: UUID())
        observers[token.id] = Observer(onFrame: onFrame, onState: onState)
        return token
    }

    func removeObserver(_ token: ObservationToken) {
        observers.removeValue(forKey: token.id)
    }

    private func receive(event: CameraStreamEvent) {
        switch event {
        case let .state(generation, state):
            receive(state: state, generation: generation)
        case .frameAvailable:
            if let frame = eventBridge.takeLatestFrame() {
                receive(frame: frame)
            }
        }
    }

    private func receive(state: State, generation: String?) {
        guard !isPermanentlyStopped || state == .stopped else { return }
        switch state {
        case .connecting:
            guard let generation else { return }
            activeGeneration = generation
        case .ready, .waitingToRetry:
            guard generation == activeGeneration else { return }
        case .stopped, .suspended:
            activeGeneration = nil
        }
        self.state = state
        onStateChange?(state)
        for observer in observers.values {
            observer.onState(state)
        }
        if state != .ready {
            latestFrame = nil
            videoSize = nil
            notifyFrameCleared()
        }
    }

    private func receive(frame: CameraFrame) {
        guard !isPermanentlyStopped,
              frame.generation == activeGeneration else { return }
        latestFrame = frame
        if videoSize != frame.size {
            videoSize = frame.size
            onVideoSizeChange?(frame.size)
        }
        for observer in observers.values {
            observer.onFrame(frame)
        }
    }

    private func notifyFrameCleared() {
        for observer in observers.values {
            observer.onFrame(nil)
        }
    }

    private struct Observer {
        let onFrame: (CameraFrame?) -> Void
        let onState: (State) -> Void
    }
}

private actor CameraStreamWorker {
    private enum StreamFailure: Error, CustomStringConvertible {
        case invalidSource
        case videoMissing
        case unsupportedCodec
        case streamEnded

        var description: String {
            switch self {
            case .invalidSource: "invalid RTSP source"
            case .videoMissing: "RTSP session has no video stream"
            case .unsupportedCodec: "camera stream is not H.264"
            case .streamEnded: "RTSP frame stream ended"
            }
        }
    }

    private let sourceURL: String
    private let onState: @Sendable (CameraStreamEvent) -> Void
    private let onFrame: @Sendable (CameraFrame) -> Void
    private var desiredRunning = false
    private var permanentlyStopped = false
    private var skipNextBackoff = false
    private var activeSession: RTSPClientSession?
    private var decoder: VideoToolboxDecoder?
    private var watchdogTask: Task<Void, Never>?
    private var backoffTask: Task<Void, Never>?
    private var activeGeneration: String?
    private var generationStartedAt: TimeInterval?
    private var lastEncodedAt: TimeInterval?
    private var lastDecodedAt: TimeInterval?
    private var lastHeartbeatAt: TimeInterval?
    private var decodedFrameCount: UInt64 = 0
    private var decodedAtLastHeartbeat: UInt64 = 0
    private var nextFrameSequence: UInt64 = 0
    private var failureCount = 0
    private var firstFrameEmitted = false
    private var emittedState: CameraStreamController.State?
    private var latestLifecycleCommandID: UInt64 = 0

    init(
        sourceURL: String,
        onState: @escaping @Sendable (CameraStreamEvent) -> Void,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) {
        self.sourceURL = sourceURL
        self.onState = onState
        self.onFrame = onFrame
    }

    func run(commandID: UInt64) async {
        guard !permanentlyStopped else { return }
        if commandID > latestLifecycleCommandID {
            latestLifecycleCommandID = commandID
            desiredRunning = true
        }

        while !permanentlyStopped, !Task.isCancelled {
            guard desiredRunning else {
                await stopGeneration(reason: "suspended")
                emitState(.suspended, generation: nil)
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let generation = UUID().uuidString
            emitState(.connecting, generation: generation)
            do {
                try await runGeneration(generation)
                if desiredRunning, !permanentlyStopped, !Task.isCancelled {
                    throw StreamFailure.streamEnded
                }
            } catch {
                await stopGeneration(reason: "failure")
                guard desiredRunning, !permanentlyStopped, !Task.isCancelled else { continue }
                failureCount += 1
                let delay: TimeInterval
                if skipNextBackoff {
                    delay = 0
                    skipNextBackoff = false
                } else {
                    delay = NativeStreamRetryPolicy.delay(afterFailure: failureCount)
                }
                DirectStreamTelemetry.record(
                    component: "stream",
                    event: "session_reconnecting",
                    videoSessionID: generation,
                    elapsedMilliseconds: Int(delay * 1_000),
                    detail: "reason=\(error)"
                )
                emitState(.waitingToRetry(delay: delay), generation: generation)
                if delay > 0 {
                    let task = Task<Void, Never> {
                        _ = try? await Task.sleep(for: .seconds(delay))
                    }
                    backoffTask = task
                    await task.value
                    backoffTask = nil
                }
            }
        }

        await stopGeneration(reason: "shutdown")
        emitState(.stopped, generation: nil)
    }

    func setDesiredRunning(_ running: Bool, commandID: UInt64) async {
        guard !permanentlyStopped, commandID > latestLifecycleCommandID else { return }
        latestLifecycleCommandID = commandID
        desiredRunning = running
        backoffTask?.cancel()
        if !running {
            DirectStreamTelemetry.record(component: "stream", event: "sleep_suspended")
            await activeSession?.abort()
        }
    }

    func retryNow(commandID: UInt64) async {
        guard !permanentlyStopped,
              commandID > latestLifecycleCommandID else { return }
        latestLifecycleCommandID = commandID
        desiredRunning = true
        skipNextBackoff = true
        failureCount = 0
        backoffTask?.cancel()
        await activeSession?.abort()
    }

    func shutdown() async {
        permanentlyStopped = true
        desiredRunning = false
        backoffTask?.cancel()
        await activeSession?.abort()
        await stopGeneration(reason: "shutdown")
    }

    private func runGeneration(_ generation: String) async throws {
        guard let source = Self.resolveSource(sourceURL) else {
            throw StreamFailure.invalidSource
        }
        activeGeneration = generation
        generationStartedAt = ProcessInfo.processInfo.systemUptime
        lastEncodedAt = nil
        lastDecodedAt = nil
        lastHeartbeatAt = generationStartedAt
        decodedFrameCount = 0
        decodedAtLastHeartbeat = 0
        firstFrameEmitted = false

        DirectStreamTelemetry.record(
            component: "stream",
            event: "session_started",
            videoSessionID: generation
        )
        let session = RTSPClientSession(
            url: source.url,
            credentials: source.credentials,
            transport: .tcp,
            userAgent: "CamBar",
            onDiagnostic: { diagnostic in
                DirectStreamTelemetry.record(
                    component: "rtsp",
                    event: "diagnostic",
                    videoSessionID: generation,
                    detail: "severity=\(diagnostic.severity) message=\(diagnostic.message)"
                )
            }
        )
        activeSession = session
        // Bound a connection or first-keyframe stall as well as a mid-stream
        // stall. Stopping this generation makes the supervisor rebuild it
        // through the one retry path.
        startWatchdog(generation: generation)
        let description = try await session.start()
        guard let video = description.video else { throw StreamFailure.videoMissing }
        guard case .h264 = video.codec else { throw StreamFailure.unsupportedCodec }
        DirectStreamTelemetry.record(
            component: "rtsp",
            event: "connected",
            videoSessionID: generation,
            elapsedMilliseconds: elapsedSinceGenerationStart()
        )

        var currentSPS = video.sps
        var currentPPS = video.pps
        var awaitingKeyframe = true
        for try await item in session.frames() {
            guard desiredRunning, !permanentlyStopped, !Task.isCancelled else { break }
            guard case let .video(frame) = item else { continue }
            lastEncodedAt = ProcessInfo.processInfo.systemUptime

            if H264StreamContinuity.isDiscontinuous(packetLoss: frame.loss) {
                decoder?.invalidate()
                decoder = nil
                awaitingKeyframe = true
                DirectStreamTelemetry.record(
                    component: "decoder",
                    event: "packet_loss_discontinuity",
                    videoSessionID: generation,
                    detail: "loss=\(frame.loss)"
                )
                continue
            }

            if let sps = frame.sps, let pps = frame.pps,
               currentSPS != sps || currentPPS != pps {
                currentSPS = sps
                currentPPS = pps
                decoder?.invalidate()
                decoder = nil
                awaitingKeyframe = true
                DirectStreamTelemetry.record(
                    component: "decoder",
                    event: "parameter_sets_changed",
                    videoSessionID: generation
                )
            }

            if awaitingKeyframe {
                guard frame.isKeyframe else { continue }
                guard let currentSPS, let currentPPS else { continue }
                try createDecoder(
                    generation: generation,
                    sps: currentSPS,
                    pps: currentPPS
                )
                awaitingKeyframe = false
            }

            do {
                try decoder?.decode(frame)
            } catch {
                DirectStreamTelemetry.record(
                    component: "decoder",
                    event: "decode_submission_failed",
                    videoSessionID: generation,
                    detail: "error=\(error)"
                )
                decoder?.invalidate()
                decoder = nil
                awaitingKeyframe = true
            }
        }
    }

    private func createDecoder(generation: String, sps: Data, pps: Data) throws {
        let decoder = try VideoToolboxDecoder(
            generation: generation,
            sps: sps,
            pps: pps,
            onFrame: { [weak self] frame in
                Task { await self?.receiveDecoded(frame) }
            },
            onError: { [weak self] status in
                Task {
                    await self?.decodeCallbackFailed(status, generation: generation)
                }
            }
        )
        self.decoder = decoder
        DirectStreamTelemetry.record(
            component: "decoder",
            event: "started",
            videoSessionID: generation,
            detail: "codec=h264 hardware=\(decoder.usesHardwareDecoder) pixel_format=nv12"
        )
    }

    private func decodeCallbackFailed(_ status: OSStatus, generation: String) async {
        guard generation == activeGeneration else { return }
        DirectStreamTelemetry.record(
            component: "decoder",
            event: "decode_callback_failed",
            videoSessionID: generation,
            detail: "status=\(status)"
        )
        await activeSession?.abort()
    }

    private func receiveDecoded(_ decoded: DecodedCameraFrame) {
        guard decoded.generation == activeGeneration,
              desiredRunning,
              !permanentlyStopped else { return }
        lastDecodedAt = decoded.decodedAt
        decodedFrameCount += 1
        nextFrameSequence += 1
        let frame = CameraFrame(
            generation: decoded.generation,
            sequence: nextFrameSequence,
            pixelBuffer: decoded.pixelBuffer,
            presentationTime: decoded.presentationTime,
            decodedAt: decoded.decodedAt
        )
        if !firstFrameEmitted {
            firstFrameEmitted = true
            failureCount = 0
            DirectStreamTelemetry.record(
                component: "video",
                event: "first_frame",
                videoSessionID: decoded.generation,
                elapsedMilliseconds: elapsedSinceGenerationStart(),
                detail: "frame_sequence=\(frame.sequence)"
            )
            emitState(.ready, generation: decoded.generation)
        }
        onFrame(frame)
    }

    private func startWatchdog(generation: String) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if await self.watchdogTick(generation: generation) { return }
            }
        }
    }

    private func emitState(
        _ state: CameraStreamController.State,
        generation: String?
    ) {
        guard state != emittedState else { return }
        emittedState = state
        onState(.state(generation: generation, state))
    }

    private func watchdogTick(generation: String) async -> Bool {
        guard generation == activeGeneration, desiredRunning, !permanentlyStopped else {
            return true
        }
        let now = ProcessInfo.processInfo.systemUptime
        let progressAt = lastDecodedAt ?? generationStartedAt ?? now
        if now - progressAt >= 5 {
            DirectStreamTelemetry.record(
                component: "stream",
                event: "stream_stalled",
                videoSessionID: generation,
                elapsedMilliseconds: Int((now - progressAt) * 1_000)
            )
            await activeSession?.abort()
            return true
        }
        if let lastHeartbeatAt, now - lastHeartbeatAt >= 5 {
            let decodedSinceHeartbeat = decodedFrameCount - decodedAtLastHeartbeat
            let frameAge = lastDecodedAt.map { Int((now - $0) * 1_000) }
            DirectStreamTelemetry.record(
                component: "video",
                event: "frame_heartbeat",
                videoSessionID: generation,
                elapsedMilliseconds: frameAge,
                detail: "decoded_frames=\(decodedFrameCount) interval_frames=\(decodedSinceHeartbeat)"
            )
            self.lastHeartbeatAt = now
            decodedAtLastHeartbeat = decodedFrameCount
        }
        return false
    }

    private func stopGeneration(reason: String) async {
        watchdogTask?.cancel()
        watchdogTask = nil
        decoder?.invalidate()
        decoder = nil
        if let activeSession {
            await activeSession.abort()
        }
        self.activeSession = nil
        if let activeGeneration {
            DirectStreamTelemetry.record(
                component: "stream",
                event: "session_stopped",
                videoSessionID: activeGeneration,
                detail: "reason=\(reason)"
            )
        }
        activeGeneration = nil
        generationStartedAt = nil
        lastEncodedAt = nil
        lastDecodedAt = nil
    }

    private func elapsedSinceGenerationStart() -> Int? {
        generationStartedAt.map {
            Int((ProcessInfo.processInfo.systemUptime - $0) * 1_000)
        }
    }

    private static func resolveSource(_ rawURL: String) -> ResolvedSource? {
        guard var components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "rtsp",
              components.host != nil else { return nil }
        let username = components.user
        let password = components.password
        components.user = nil
        components.password = nil
        guard let url = components.string else { return nil }
        let credentials = username.map {
            Credentials(username: $0, password: password ?? "")
        }
        return ResolvedSource(url: url, credentials: credentials)
    }

    private struct ResolvedSource {
        let url: String
        let credentials: Credentials?
    }
}
