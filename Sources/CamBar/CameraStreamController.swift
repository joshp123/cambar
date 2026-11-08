import CamBarCore
import CoreMedia
import CoreVideo
import Foundation
import IPCamKit
import Network

struct CameraFrame: @unchecked Sendable {
    let generation: String
    let isFallbackStream: Bool
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

        /// Suspended is deliberate (sleep, Low Power Mode), not a failure.
        var meansCameraUnavailable: Bool {
            switch self {
            case .waitingToRetry, .stopped: true
            case .connecting, .ready, .suspended: false
            }
        }
    }

    struct ObservationToken: Hashable {
        fileprivate let id: UUID
    }

    var onStateChange: ((State) -> Void)?
    var onVideoSizeChange: ((CGSize) -> Void)?
    /// The fallback stream's height, or nil while on the main stream.
    var onFallbackStreamHeightChange: ((Int?) -> Void)?
    private(set) var state: State = .stopped
    private(set) var latestFrame: CameraFrame?
    private(set) var videoSize: CGSize?
    private var fallbackStreamHeight: Int?

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
    private var activeViewers: Set<String> = []
    private var settledNetworkChangeTask: Task<Void, Never>?
    private var isStarted = false
    private var isAsleep = false
    private var isStreaming = false
    /// `CAMBAR_LOW_POWER_MODE=1` lets agents test this without changing the
    /// Mac's setting, which needs an administrator.
    private static let lowPowerModeOverride = ProcessInfo.processInfo
        .environment["CAMBAR_LOW_POWER_MODE"].map { $0 == "1" }
    private(set) var isLowPowerMode = lowPowerModeOverride
        ?? ProcessInfo.processInfo.isLowPowerModeEnabled
    private var powerStateObserver: NSObjectProtocol?
    private var viewingCommandID: UInt64 = 0
    private let networkMonitor = NWPathMonitor()
    private var networkSummary: String?

    init(sourceURL: String) {
        let eventBridge = CameraStreamEventBridge()
        self.eventBridge = eventBridge
        worker = CameraStreamWorker(
            mainSourceURL: sourceURL,
            fallbackSourceURL: StreamSourceResolver.fallbackRtspURL(forMain: sourceURL),
            onState: { eventBridge.yield($0) },
            onFrame: { eventBridge.yield(frame: $0) }
        )
        eventTask = Task { @MainActor [weak self, stream = eventBridge.stream] in
            for await event in stream {
                guard let self else { return }
                self.receive(event: event)
            }
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            // Only interfaces with an address can carry the stream.
            let addressed = Array(Set(path.availableInterfaces.map(\.name))).sorted().compactMap { name in
                let networks = InterfaceAddresses.ipv4(of: name)
                return networks.isEmpty ? nil : "\(name)=" + networks.map(\.description).joined(separator: "+")
            }
            let summary = "status=\(path.status) interfaces=\(addressed.joined(separator: ","))"
            MainActor.assumeIsolated { self?.networkChanged(summary) }
        }
        networkMonitor.start(queue: .main)
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerStateChanged() }
        }
    }

    private func powerStateChanged() {
        let lowPowerMode = Self.lowPowerModeOverride ?? ProcessInfo.processInfo.isLowPowerModeEnabled
        guard lowPowerMode != isLowPowerMode else { return }
        isLowPowerMode = lowPowerMode
        reconcileStreaming(reason: lowPowerMode ? "low power mode on" : "low power mode off")
    }

    /// Low Power Mode trades instant opening for no stream while the menu is
    /// closed: opening then connects from cold, in about 2 s.
    private func reconcileStreaming(reason: String) {
        let shouldStream = StreamWarmthPolicy.shouldStream(
            appStarted: isStarted,
            asleep: isAsleep,
            lowPowerMode: isLowPowerMode,
            viewed: !activeViewers.isEmpty
        )
        guard shouldStream != isStreaming, !isPermanentlyStopped else { return }
        isStreaming = shouldStream
        DirectStreamTelemetry.record(
            component: "stream",
            event: shouldStream ? "streaming_started" : "streaming_paused",
            detail: "reason=\(reason) low_power_mode=\(isLowPowerMode)"
        )
        if shouldStream {
            runWorker()
        } else {
            pauseWorker()
        }
    }

    /// Interfaces appear and vanish constantly on hotspots and VPNs, so wait
    /// for the network to settle and let the worker decide whether the route to
    /// the camera actually changed. A working session is never cut for nothing.
    private func networkChanged(_ summary: String) {
        guard summary != networkSummary else { return }
        let isFirstReport = networkSummary == nil
        networkSummary = summary
        DirectStreamTelemetry.record(component: "network", event: "network_changed", detail: summary)
        guard !isFirstReport, supervisorTask != nil else { return }
        settledNetworkChangeTask?.cancel()
        settledNetworkChangeTask = Task { [worker] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await worker?.networkChanged()
        }
    }

    func start() {
        isStarted = true
        reconcileStreaming(reason: "launch")
    }

    private func runWorker() {
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
        guard !isPermanentlyStopped, isStreaming else { return }
        lifecycleCommandID &+= 1
        let commandID = lifecycleCommandID
        if supervisorTask == nil {
            runWorker()
        } else {
            Task { await worker.retryNow(commandID: commandID) }
        }
    }

    func suspendForSleep() {
        isAsleep = true
        reconcileStreaming(reason: "sleep")
    }

    func resumeAfterWake() {
        isAsleep = false
        Task { await worker.networkChanged() }  // Waking often means a new network.
        reconcileStreaming(reason: "wake")
    }

    private func pauseWorker() {
        latestFrame = nil
        videoSize = nil
        notifyFrameCleared()
        lifecycleCommandID &+= 1
        let commandID = lifecycleCommandID
        Task { await worker.setDesiredRunning(false, commandID: commandID) }
    }


    func shutdown() {
        guard !isPermanentlyStopped else { return }
        isPermanentlyStopped = true
        networkMonitor.cancel()
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
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

    /// Decoding is the expensive part, so it runs only while a surface is
    /// visible. Hidden, the worker just keeps frames since the last keyframe.
    func setViewer(_ viewer: String, active: Bool) {
        let wasViewed = !activeViewers.isEmpty
        if active {
            activeViewers.insert(viewer)
        } else {
            activeViewers.remove(viewer)
        }
        guard !activeViewers.isEmpty != wasViewed else { return }
        viewingCommandID &+= 1
        let commandID = viewingCommandID
        let viewed = !activeViewers.isEmpty
        Task { await worker.setViewed(viewed, commandID: commandID) }
        reconcileStreaming(reason: viewed ? "opened" : "closed")
        // Someone is looking: do not make them wait out a retry delay.
        if viewed, state != .ready {
            retryNow()
        }
    }

    /// Agent test hook: take the fallback path without needing a bad link.
    func forceFallbackStream() {
        Task { await worker.forceFallback() }
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
        // Size the surfaces for the main stream; the fallback stream is drawn
        // into the same frame rather than shrinking the window.
        if !frame.isFallbackStream, videoSize != frame.size {
            videoSize = frame.size
            onVideoSizeChange?(frame.size)
        }
        let height = frame.isFallbackStream ? Int(frame.size.height) : nil
        if height != fallbackStreamHeight {
            fallbackStreamHeight = height
            onFallbackStreamHeightChange?(height)
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
        case noTrustedRoute(String)
        case videoMissing
        case unsupportedCodec
        case streamEnded

        var description: String {
            switch self {
            case .invalidSource: "invalid RTSP source"
            case let .noTrustedRoute(reason): "not connecting: \(reason)"
            case .videoMissing: "RTSP session has no video stream"
            case .unsupportedCodec: "camera stream is neither H.264 nor H.265"
            case .streamEnded: "RTSP frame stream ended"
            }
        }
    }

    private let mainSourceURL: String
    private let fallbackSourceURL: String?
    /// Set while the main stream cannot keep up with the link; cleared to try
    /// main again after `NativeStreamFallbackPolicy.retryMainAfter`.
    private var fallbackSince: TimeInterval?
    private var activeGenerationIsFallback = false
    private var pendingStreamSwitch: String?
    private var lagTracker = RealTimeLagTracker()
    private let pathMonitor = NWPathMonitor()
    private var activeRoute: CameraRoute?
    private var certificateLearnedThisLaunch = false
    private var rtspConnected = false
    /// Why the watchdog cut the session, which says more than the error the
    /// aborted socket reports.
    private var watchdogStopReason: String?
    private var isViewed = false
    private var latestViewingCommandID: UInt64 = 0
    private var awaitingKeyframe = true
    /// Compressed frames since the last keyframe: everything a decoder needs
    /// to produce the newest picture, bounded by the camera's keyframe spacing.
    private var framesSinceKeyframe: [PublicVideoFrame] = []
    /// When a usable frame last joined the cache: a hidden session's progress.
    private var lastCachedAt: TimeInterval?
    private var pendingCatchUp: (startedAt: TimeInterval, newestTimestamp: TimeInterval, frames: Int)?
    private var mediaSecondsSinceHeartbeat = 0.0
    private var heartbeatsSinceFirstFrame = 0
    private var resourceSampleAtHeartbeat = ProcessResourceUsage.sample()
    private let onState: @Sendable (CameraStreamEvent) -> Void
    private let onFrame: @Sendable (CameraFrame) -> Void
    private var desiredRunning = false
    private var permanentlyStopped = false
    private var skipNextBackoff = false
    private var activeSession: RTSPClientSession?
    private var decoder: VideoToolboxDecoder?
    private var decodedFramesTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var backoffTask: Task<Void, Never>?
    private var activeGeneration: String?
    private var generationStartedAt: TimeInterval?
    private var lastDecodedAt: TimeInterval?
    private var lastHeartbeatAt: TimeInterval?
    private var decodedFrameCount: UInt64 = 0
    private var decodedAtLastHeartbeat: UInt64 = 0
    private var encodedFrameCount: UInt64 = 0
    private var encodedAtLastHeartbeat: UInt64 = 0
    private var encodedBytesSinceHeartbeat = 0
    private var encodedBytesTotal = 0
    private var previousEncodedTimestamp: TimeInterval?
    private var previousEncodedAt: TimeInterval?
    private var encodedJitterSamples = 0
    private var encodedJitterTotalMilliseconds = 0.0
    private var encodedJitterMaximumMilliseconds = 0.0
    private var encodedGapMaximumMilliseconds = 0.0
    private var nextFrameSequence: UInt64 = 0
    private var failureCount = 0
    private var firstFrameEmitted = false
    private var emittedState: CameraStreamController.State?
    private var latestLifecycleCommandID: UInt64 = 0

    init(
        mainSourceURL: String,
        fallbackSourceURL: String?,
        onState: @escaping @Sendable (CameraStreamEvent) -> Void,
        onFrame: @escaping @Sendable (CameraFrame) -> Void
    ) {
        self.mainSourceURL = mainSourceURL
        self.fallbackSourceURL = fallbackSourceURL
        pathMonitor.start(queue: DispatchQueue(label: "CamBar.camera-route"))
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
                let failureReason = watchdogStopReason ?? "\(error)"
                watchdogStopReason = nil
                if let streamSwitch = pendingStreamSwitch {
                    pendingStreamSwitch = nil
                    await stopGeneration(reason: streamSwitch)
                    DirectStreamTelemetry.record(
                        component: "stream",
                        event: "stream_switched",
                        videoSessionID: generation,
                        detail: "to=\(fallbackSince == nil ? "main" : "fallback") reason=\(streamSwitch)"
                    )
                    failureCount = 0
                    continue
                }
                await stopGeneration(reason: failureReason)
                guard desiredRunning, !permanentlyStopped, !Task.isCancelled else { continue }
                failureCount += 1
                if fallbackSince == nil, fallbackSourceURL != nil,
                   failureCount >= NativeStreamFallbackPolicy.mainFailuresBeforeFallback {
                    fallbackSince = ProcessInfo.processInfo.systemUptime
                    DirectStreamTelemetry.record(
                        component: "stream",
                        event: "stream_switched",
                        videoSessionID: generation,
                        detail: "to=fallback reason=main stream failed \(failureCount) times"
                    )
                }
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
                    detail: "reason=\(failureReason)"
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

    /// A settled network change. Main gets another chance, and the session
    /// reconnects only if the route to the camera changed or none is working.
    func networkChanged() async {
        fallbackSince = nil
        await reassessRoute(trigger: "network changed")
    }

    private func reassessRoute(trigger: String) async {
        guard let activeRoute, activeSession != nil, let host = Self.resolveSource(mainSourceURL)?.host else {
            skipNextBackoff = true
            failureCount = 0
            backoffTask?.cancel()
            return
        }
        let route = await CameraRoute.choose(host: host, interfaces: pathMonitor.currentPath.availableInterfaces)
        let routeChanged = route.decision != activeRoute.decision || route.interface?.name != activeRoute.interface?.name
        guard routeChanged || activeGenerationIsFallback else { return }
        pendingStreamSwitch = routeChanged ? "\(trigger), route now \(route)" : "\(trigger), trying main"
        await activeSession?.abort()
    }

    /// Learns or refreshes the camera certificate through Tailscale; a newly
    /// learned one may allow the direct route at once.
    private func learnCameraCertificate(host: String, over tailscale: NWInterface) async {
        guard let changed = await CameraIdentity.learn(host: host, over: tailscale) else { return }
        certificateLearnedThisLaunch = true
        if changed {
            await reassessRoute(trigger: "camera certificate learned")
        }
    }

    func setViewed(_ viewed: Bool, commandID: UInt64) async {
        guard commandID > latestViewingCommandID else { return }
        latestViewingCommandID = commandID
        guard viewed != isViewed else { return }
        isViewed = viewed
        DirectStreamTelemetry.record(
            component: "stream",
            event: viewed ? "decoding_started" : "decoding_stopped",
            videoSessionID: activeGeneration,
            detail: "cached_frames=\(framesSinceKeyframe.count)"
        )
        await activeSession?.setMinimumReadBytes(minimumReadBytes)
        guard viewed else { return }
        lastDecodedAt = ProcessInfo.processInfo.systemUptime
        decodeCachedFrames()
    }

    /// Hidden, batch socket reads: waking for every packet is the main cost of
    /// receiving, and nobody needs the newest few milliseconds.
    private var minimumReadBytes: Int {
        isViewed ? 1 : 16_384
    }

    /// Runs the decoder through the cached frames, showing only the newest.
    private func decodeCachedFrames() {
        guard let decoder, !awaitingKeyframe else { return }
        guard NativeFrameFreshness.canReplayCachedFrames(
            now: ProcessInfo.processInfo.systemUptime,
            lastReceivedAt: previousEncodedAt
        ) else {
            // Reception has stalled, so the cache is old. Wait for live frames;
            // the open deadline and watchdog reconnect if none come.
            DirectStreamTelemetry.record(
                component: "stream",
                event: "stale_cache_discarded",
                videoSessionID: activeGeneration,
                detail: "cached_frames=\(framesSinceKeyframe.count)"
            )
            discardDecoder()
            awaitingKeyframe = true
            framesSinceKeyframe = []
            return
        }
        let cached = framesSinceKeyframe
        if let newest = cached.last {
            pendingCatchUp = (ProcessInfo.processInfo.systemUptime, newest.timestamp, cached.count)
        }
        do {
            for (index, frame) in cached.enumerated() {
                try decoder.decode(frame, output: index == cached.count - 1)
            }
        } catch {
            DirectStreamTelemetry.record(
                component: "decoder",
                event: "decode_submission_failed",
                videoSessionID: activeGeneration,
                detail: "error=\(error)"
            )
            discardDecoder()
            awaitingKeyframe = true
        }
    }

    func forceFallback() async {
        guard fallbackSince == nil, fallbackSourceURL != nil else { return }
        fallbackSince = ProcessInfo.processInfo.systemUptime
        pendingStreamSwitch = "forced by test"
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
        // Checked here too: a fallback that never decodes has no heartbeats.
        if let fallbackSince,
           ProcessInfo.processInfo.systemUptime - fallbackSince >= NativeStreamFallbackPolicy.retryMainAfter {
            self.fallbackSince = nil
        }
        activeGenerationIsFallback = fallbackSince != nil
        let sourceURL = activeGenerationIsFallback ? fallbackSourceURL ?? mainSourceURL : mainSourceURL
        guard let source = Self.resolveSource(sourceURL) else {
            throw StreamFailure.invalidSource
        }
        activeGeneration = generation
        generationStartedAt = ProcessInfo.processInfo.systemUptime
        lastDecodedAt = nil
        lastHeartbeatAt = generationStartedAt
        decodedFrameCount = 0
        decodedAtLastHeartbeat = 0
        encodedFrameCount = 0
        encodedAtLastHeartbeat = 0
        encodedBytesSinceHeartbeat = 0
        encodedBytesTotal = 0
        previousEncodedTimestamp = nil
        previousEncodedAt = nil
        resetEncodedCadenceWindow()
        firstFrameEmitted = false
        lagTracker = RealTimeLagTracker()
        awaitingKeyframe = true
        framesSinceKeyframe = []
        lastCachedAt = nil
        pendingCatchUp = nil
        mediaSecondsSinceHeartbeat = 0
        heartbeatsSinceFirstFrame = 0

        let transport = rtspTransport
        let transportName = switch transport {
        case .tcp: "tcp"
        case .udp: "udp"
        }
        DirectStreamTelemetry.record(
            component: "stream",
            event: "session_started",
            videoSessionID: generation,
            detail: "transport=\(transportName) stream=\(activeGenerationIsFallback ? "fallback" : "main") url=\(StreamSourceResolver.redactRtspCredentials(in: sourceURL))"
        )
        let route = await CameraRoute.choose(
            host: source.host,
            interfaces: pathMonitor.currentPath.availableInterfaces
        )
        activeRoute = route
        rtspConnected = false
        guard route.decision != .unavailable else {
            throw StreamFailure.noTrustedRoute(route.reason)
        }
        DirectStreamTelemetry.record(
            component: "route",
            event: "route_chosen",
            videoSessionID: generation,
            detail: "route=\(route)"
        )
        let session = RTSPClientSession(
            url: source.url,
            credentials: source.credentials,
            transport: transport,
            requiredInterface: route.interface,
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
        await session.setMinimumReadBytes(minimumReadBytes)
        rtspConnected = true
        if route.decision == .tailscale, let tailscale = route.interface,
           !certificateLearnedThisLaunch || route.localCheck == .otherDevice {
            Task { await self.learnCameraCertificate(host: source.host, over: tailscale) }
        }
        DirectStreamTelemetry.record(
            component: "rtsp",
            event: "connected",
            videoSessionID: generation,
            elapsedMilliseconds: elapsedSinceGenerationStart()
        )

        var parameterSets = Self.parameterSets(
            codec: video.codec, vps: video.vps, sps: video.sps, pps: video.pps
        )
        for try await item in session.frames() {
            guard desiredRunning, !permanentlyStopped, !Task.isCancelled else { break }
            guard case let .video(frame) = item else { continue }
            recordEncodedFrame(timestamp: frame.timestamp)
            let frameBytes = frame.nalus.reduce(0) { $0 + $1.count }
            encodedBytesSinceHeartbeat += frameBytes
            encodedBytesTotal += frameBytes

            if frame.loss > 0 {
                discardDecoder()
                awaitingKeyframe = true
                framesSinceKeyframe = []
                DirectStreamTelemetry.record(
                    component: "decoder",
                    event: "packet_loss_discontinuity",
                    videoSessionID: generation,
                    detail: "loss=\(frame.loss)"
                )
                continue
            }

            if let updated = Self.parameterSets(
                codec: video.codec,
                vps: frame.vps ?? parameterSets?.vps,
                sps: frame.sps,
                pps: frame.pps
            ), updated != parameterSets {
                if parameterSets != nil {
                    discardDecoder()
                    awaitingKeyframe = true
                    framesSinceKeyframe = []
                    DirectStreamTelemetry.record(
                        component: "decoder",
                        event: "parameter_sets_changed",
                        videoSessionID: generation
                    )
                }
                parameterSets = updated
            }

            if awaitingKeyframe {
                guard frame.isKeyframe else { continue }
                guard let parameterSets else { continue }
                try createDecoder(generation: generation, parameterSets: parameterSets)
                awaitingKeyframe = false
            }

            if frame.isKeyframe {
                framesSinceKeyframe = [frame]
            } else {
                framesSinceKeyframe.append(frame)
            }
            guard framesSinceKeyframe.count <= NativeFrameFreshness.maximumCachedFrames else {
                DirectStreamTelemetry.record(
                    component: "stream",
                    event: "keyframes_stopped",
                    videoSessionID: generation,
                    detail: "cached_frames=\(framesSinceKeyframe.count)"
                )
                discardDecoder()
                awaitingKeyframe = true
                framesSinceKeyframe = []
                continue
            }
            lastCachedAt = ProcessInfo.processInfo.systemUptime
            // Decode the first picture hidden too: it proves the decoder works
            // and is what marks the stream ready.
            guard isViewed || !firstFrameEmitted else { continue }

            do {
                try decoder?.decode(frame)
            } catch {
                DirectStreamTelemetry.record(
                    component: "decoder",
                    event: "decode_submission_failed",
                    videoSessionID: generation,
                    detail: "error=\(error)"
                )
                discardDecoder()
                awaitingKeyframe = true
                framesSinceKeyframe = []
            }
        }
    }

    private var rtspTransport: Transport {
        ProcessInfo.processInfo.environment["CAMBAR_RTSP_TRANSPORT"]?.lowercased() == "udp"
            ? .udp
            : .tcp
    }

    private static func parameterSets(
        codec: VideoCodec, vps: Data?, sps: Data?, pps: Data?
    ) -> VideoParameterSets? {
        guard let sps, let pps else { return nil }
        switch codec {
        case .h264: return .h264(sps: sps, pps: pps)
        case .h265: return vps.map { .h265(vps: $0, sps: sps, pps: pps) }
        }
    }

    private func createDecoder(generation: String, parameterSets: VideoParameterSets) throws {
        // VideoToolbox emits frames in order on its own thread; one stream per
        // decoder carries them into the actor in order, keeping only the newest
        // if the actor falls behind.
        let (decodedFrames, continuation) = AsyncStream.makeStream(
            of: DecodedCameraFrame.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let decoder = try VideoToolboxDecoder(
            generation: generation,
            parameterSets: parameterSets,
            onFrame: { continuation.yield($0) },
            onError: { [weak self] status in
                Task {
                    await self?.decodeCallbackFailed(status, generation: generation)
                }
            }
        )
        self.decoder = decoder
        decodedFramesTask = Task { [weak self] in
            for await frame in decodedFrames {
                await self?.receiveDecoded(frame)
            }
        }
        DirectStreamTelemetry.record(
            component: "decoder",
            event: "started",
            videoSessionID: generation,
            detail: "codec=\(decoder.codec.rawValue) hardware=\(decoder.usesHardwareDecoder) pixel_format=nv12"
        )
    }

    private func discardDecoder() {
        decoder?.invalidate()
        decoder = nil
        decodedFramesTask?.cancel()
        decodedFramesTask = nil
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
        if let catchUp = pendingCatchUp {
            pendingCatchUp = nil
            let gap = catchUp.newestTimestamp - decoded.presentationTime.seconds
            DirectStreamTelemetry.record(
                component: "decoder",
                event: "caught_up",
                videoSessionID: decoded.generation,
                elapsedMilliseconds: Int((decoded.decodedAt - catchUp.startedAt) * 1_000),
                detail: "cached_frames=\(catchUp.frames) behind_newest_cached_ms=\(Int(gap * 1_000))"
            )
        }
        nextFrameSequence += 1
        let frame = CameraFrame(
            generation: decoded.generation,
            isFallbackStream: activeGenerationIsFallback,
            sequence: nextFrameSequence,
            pixelBuffer: decoded.pixelBuffer,
            presentationTime: decoded.presentationTime,
            decodedAt: decoded.decodedAt
        )
        if !firstFrameEmitted {
            firstFrameEmitted = true
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
        // Hidden sessions decode nothing: progress is a usable frame in the cache.
        let lastProgress = isViewed || !firstFrameEmitted ? lastDecodedAt : lastCachedAt
        let progressAt = lastProgress ?? generationStartedAt ?? now
        if now - progressAt >= 5 {
            watchdogStopReason = !rtspConnected
                ? "camera did not answer within 5 s"
                : firstFrameEmitted ? "no video for 5 s" : "no video within 5 s of connecting"
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
            let encodedSinceHeartbeat = encodedFrameCount - encodedAtLastHeartbeat
            let frameAge = (isViewed ? lastDecodedAt : previousEncodedAt).map { Int((now - $0) * 1_000) }
            let encodedKilobitsPerSecond = Int(
                Double(encodedBytesSinceHeartbeat * 8) / (now - lastHeartbeatAt) / 1_000
            )
            let averageEncodedJitter = encodedJitterSamples > 0
                ? encodedJitterTotalMilliseconds / Double(encodedJitterSamples)
                : 0
            // Video time received per second of wall time. Below 1 the stream
            // is falling behind real time, so what is shown gets staler.
            let heartbeatWallSeconds = now - lastHeartbeatAt
            let heartbeatMediaSeconds = mediaSecondsSinceHeartbeat
            let realTimeRatio = heartbeatMediaSeconds / heartbeatWallSeconds
            let resources = ProcessResourceUsage.sample()
            let cpuPercent = resources.cpuPercent(since: resourceSampleAtHeartbeat)
            resourceSampleAtHeartbeat = resources
            DirectStreamTelemetry.record(
                component: "video",
                event: "frame_heartbeat",
                videoSessionID: generation,
                elapsedMilliseconds: frameAge,
                detail: "stream=\(activeGenerationIsFallback ? "fallback" : "main") viewed=\(isViewed) real_time_ratio=\(String(format: "%.2f", realTimeRatio)) seconds_behind=\(String(format: "%.2f", lagTracker.secondsBehind)) cpu_percent=\(String(format: "%.1f", cpuPercent)) memory_mb=\(resources.memoryMegabytes) encoded_kbps=\(encodedKilobitsPerSecond) decoded_frames=\(decodedFrameCount) decoded_interval=\(decodedSinceHeartbeat) encoded_frames=\(encodedFrameCount) encoded_interval=\(encodedSinceHeartbeat) encoded_jitter_avg_ms=\(String(format: "%.2f", averageEncodedJitter)) encoded_jitter_max_ms=\(String(format: "%.2f", encodedJitterMaximumMilliseconds)) encoded_gap_max_ms=\(String(format: "%.2f", encodedGapMaximumMilliseconds))"
            )
            self.lastHeartbeatAt = now
            decodedAtLastHeartbeat = decodedFrameCount
            encodedAtLastHeartbeat = encodedFrameCount
            encodedBytesSinceHeartbeat = 0
            mediaSecondsSinceHeartbeat = 0
            resetEncodedCadenceWindow()
            if firstFrameEmitted {
                heartbeatsSinceFirstFrame += 1
                // The first window after the first frame includes setup time.
                if heartbeatsSinceFirstFrame > 1 {
                    lagTracker.add(wallSeconds: heartbeatWallSeconds, mediaSeconds: heartbeatMediaSeconds)
                    if lagTracker.secondsBehind < 1 {
                        failureCount = 0  // A session that keeps up has proved itself.
                    }
                }
                if let reason = streamSwitchReason(now: now) {
                    pendingStreamSwitch = reason
                    await activeSession?.abort()
                    return true
                }
            }
        }
        return false
    }

    /// Fall back when main cannot keep up; try main again after a while.
    /// Uses only timings already recorded per frame, so it costs nothing.
    private func streamSwitchReason(now: TimeInterval) -> String? {
        if let fallbackSince {
            guard now - fallbackSince >= NativeStreamFallbackPolicy.retryMainAfter else { return nil }
            self.fallbackSince = nil
            return "retrying main after \(Int(NativeStreamFallbackPolicy.retryMainAfter)) s"
        }
        let secondsBehind = lagTracker.secondsBehind
        guard fallbackSourceURL != nil,
              secondsBehind >= NativeStreamFallbackPolicy.maximumSecondsBehind else { return nil }
        fallbackSince = now
        return "main \(String(format: "%.1f", secondsBehind)) s behind real time"
    }

    private func recordEncodedFrame(timestamp: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        encodedFrameCount += 1
        if let previousEncodedTimestamp, let previousEncodedAt {
            let presentationDelta = timestamp - previousEncodedTimestamp
            let arrivalDelta = now - previousEncodedAt
            encodedGapMaximumMilliseconds = max(
                encodedGapMaximumMilliseconds,
                arrivalDelta * 1_000
            )
            if presentationDelta > 0,
               presentationDelta <= NativeFrameCadence.discontinuityThreshold {
                mediaSecondsSinceHeartbeat += presentationDelta
            }
            if presentationDelta > 0,
               presentationDelta <= NativeFrameCadence.maximumFrameDuration {
                let jitterMilliseconds = abs(arrivalDelta - presentationDelta) * 1_000
                encodedJitterSamples += 1
                encodedJitterTotalMilliseconds += jitterMilliseconds
                encodedJitterMaximumMilliseconds = max(
                    encodedJitterMaximumMilliseconds,
                    jitterMilliseconds
                )
            }
        }
        previousEncodedTimestamp = timestamp
        previousEncodedAt = now
    }

    private func resetEncodedCadenceWindow() {
        encodedJitterSamples = 0
        encodedJitterTotalMilliseconds = 0
        encodedJitterMaximumMilliseconds = 0
        encodedGapMaximumMilliseconds = 0
    }

    private func stopGeneration(reason: String) async {
        watchdogTask?.cancel()
        watchdogTask = nil
        discardDecoder()
        if let activeSession {
            await activeSession.abort()
        }
        self.activeSession = nil
        if let activeGeneration {
            let now = ProcessInfo.processInfo.systemUptime
            let lastPacketAge = previousEncodedAt.map { "\(Int((now - $0) * 1_000))" } ?? "none"
            DirectStreamTelemetry.record(
                component: "stream",
                event: "session_stopped",
                videoSessionID: activeGeneration,
                elapsedMilliseconds: elapsedSinceGenerationStart(),
                detail: "reason=\(reason) encoded_frames=\(encodedFrameCount) decoded_frames=\(decodedFrameCount) encoded_bytes=\(encodedBytesTotal) last_packet_age_ms=\(lastPacketAge)"
            )
        }
        activeGeneration = nil
        generationStartedAt = nil
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
        return ResolvedSource(url: url, host: components.host ?? "", credentials: credentials)
    }

    private struct ResolvedSource {
        let url: String
        let host: String
        let credentials: Credentials?
    }
}
