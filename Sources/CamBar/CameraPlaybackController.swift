import AVFoundation
import AppKit
import CamBarCore
import CoreMedia

@MainActor
final class CameraPlaybackController {
    enum Surface: String, Sendable {
        case menu
        case window
    }

    let container: CameraVideoContainerView

    private let stream: CameraStreamController
    private let surface: Surface
    private var observationToken: CameraStreamController.ObservationToken?
    private var isVisible = false
    private var isSuspended = false
    private var currentOpenID: String?
    private var openStartedAt: TimeInterval?
    private var minimumFreshSequence: UInt64?
    private var coverShownAt: TimeInterval?
    private var connectionIndicatorRecorded = false
    private var surfacePrepared = false
    private var presentationPending = false
    private var preparationTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var openDeadlineTask: Task<Void, Never>?
    private var surfaceAttemptID: UInt64 = 0

    init(
        stream: CameraStreamController,
        surface: Surface,
        cornerStyle: CameraVideoCornerStyle
    ) {
        self.stream = stream
        self.surface = surface
        self.container = CameraVideoContainerView(cornerStyle: cornerStyle)
        container.onIndicatorShown = { [weak self] in
            self?.recordConnectionIndicatorShown()
        }
        container.onRendererLostDisplay = { [weak self] in
            self?.rendererLostDisplay()
        }
        observationToken = stream.addObserver(
            onFrame: { [weak self] frame in
                self?.receive(frame: frame)
            },
            onState: { [weak self] state in
                self?.receive(state: state)
            }
        )
    }

    func show(openID: String, startedAt: TimeInterval) {
        isSuspended = false
        isVisible = true
        currentOpenID = openID
        openStartedAt = startedAt
        minimumFreshSequence = stream.latestSequence
        connectionIndicatorRecorded = false
        showPlaybackCover(indicatorDelay: 0.4)
        DirectStreamTelemetry.record(
            component: "video",
            event: "playback_open_started",
            surface: surface.rawValue,
            openID: openID,
            videoSessionID: stream.latestFrame?.generation,
            detail: "baseline_sequence=\(stream.latestSequence)"
        )

        restartSurfaceWaiting(baselineSequence: stream.latestSequence)
        let baselineSequence = stream.latestSequence
        openDeadlineTask?.cancel()
        openDeadlineTask = nil
        if stream.state == .ready {
            openDeadlineTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled,
                      let self,
                      self.isVisible,
                      self.currentOpenID == openID,
                      self.minimumFreshSequence != nil else { return }
                DirectStreamTelemetry.record(
                    component: "video",
                    event: "open_frame_deadline_exceeded",
                    surface: self.surface.rawValue,
                    openID: openID,
                    videoSessionID: self.stream.latestFrame?.generation,
                    elapsedMilliseconds: 250
                )
                self.recoverStreamIfStalled(
                    baselineSequence: baselineSequence,
                    openedAt: startedAt
                )
            }
        }
    }

    func hide() {
        isVisible = false
        currentOpenID = nil
        openStartedAt = nil
        minimumFreshSequence = nil
        connectionIndicatorRecorded = false
        coverShownAt = nil
        surfacePrepared = false
        presentationPending = false
        surfaceAttemptID &+= 1
        container.beginSurfaceAttempt(surfaceAttemptID)
        preparationTask?.cancel()
        preparationTask = nil
        presentationTask?.cancel()
        presentationTask = nil
        openDeadlineTask?.cancel()
        openDeadlineTask = nil
        container.showCover(true, animated: false)
    }

    func suspend() {
        isSuspended = true
        hide()
    }

    func resumeAfterPopout() {
        isSuspended = false
    }

    func retryNow() {
        stream.retryNow()
    }

    func shutdown() {
        hide()
        isSuspended = true
        if let observationToken {
            stream.removeObserver(observationToken)
            self.observationToken = nil
        }
        container.shutdown()
    }

    private func receive(frame: CameraFrame?) {
        guard isVisible, !isSuspended else { return }
        guard let frame else {
            if surfacePrepared || presentationPending || minimumFreshSequence == nil {
                restartSurfaceWaiting(baselineSequence: stream.latestSequence)
            }
            return
        }

        if let baseline = minimumFreshSequence {
            guard frame.sequence > baseline else { return }
            tryPresentOpeningFrame()
        } else {
            if !container.present(frame) {
                recoverRenderer(after: frame)
            }
        }
    }

    private func receive(state: CameraStreamController.State) {
        guard isVisible, !isSuspended else { return }
        guard state != .ready else { return }
        restartSurfaceWaiting(baselineSequence: stream.latestSequence)
    }

    private func tryPresentOpeningFrame() {
        guard isVisible,
              !isSuspended,
              surfacePrepared,
              !presentationPending,
              let baseline = minimumFreshSequence,
              let openedAt = openStartedAt,
              let frame = stream.latestFrame else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let cached = NativeFrameFreshness.canPresentCachedFrame(
            now: now,
            decodedAt: frame.decodedAt
        )
        guard cached || NativeFrameFreshness.isPostOpenFrame(
            sequence: frame.sequence,
            baselineSequence: baseline,
            decodedAt: frame.decodedAt,
            openedAt: openedAt
        ) else { return }

        let openID = currentOpenID
        let attemptID = surfaceAttemptID
        presentationPending = true
        presentationTask = Task { [weak self] in
            guard let self else { return }
            let visiblyReady = await self.container.presentOpening(
                frame,
                attemptID: attemptID
            )
            guard !Task.isCancelled,
                  self.isVisible,
                  self.currentOpenID == openID,
                  self.surfaceAttemptID == attemptID,
                  self.stream.latestFrame?.generation == frame.generation else { return }
            self.presentationTask = nil
            self.presentationPending = false
            guard visiblyReady else {
                DirectStreamTelemetry.record(
                    component: "renderer",
                    event: "visible_frame_timeout",
                    surface: self.surface.rawValue,
                    openID: openID,
                    videoSessionID: frame.generation
                )
                self.restartSurfaceWaiting(baselineSequence: self.stream.latestSequence)
                return
            }
            self.minimumFreshSequence = nil
            self.openDeadlineTask?.cancel()
            self.openDeadlineTask = nil
            self.hidePlaybackCover()
            let elapsed = self.openStartedAt.map {
                Int((ProcessInfo.processInfo.systemUptime - $0) * 1_000)
            }
            DirectStreamTelemetry.record(
                component: "video",
                event: "live_view",
                surface: self.surface.rawValue,
                openID: openID,
                videoSessionID: frame.generation,
                elapsedMilliseconds: elapsed,
                detail: "frame_sequence=\(frame.sequence) cached=\(cached) frame_age_ms=\(Int((ProcessInfo.processInfo.systemUptime - frame.decodedAt) * 1_000))"
            )
        }
    }

    private func startSurfacePreparation(openID: String, attemptID: UInt64) {
        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            guard let self else { return }
            let prepared = await self.container.prepareForOpen(attemptID: attemptID)
            guard !Task.isCancelled,
                  prepared,
                  self.isVisible,
                  self.currentOpenID == openID,
                  self.surfaceAttemptID == attemptID else { return }
            self.preparationTask = nil
            self.surfacePrepared = true
            self.tryPresentOpeningFrame()
        }
    }

    private func recoverRenderer(after frame: CameraFrame) {
        guard preparationTask == nil,
              let openID = currentOpenID else { return }
        DirectStreamTelemetry.record(
            component: "renderer",
            event: "surface_recovery_started",
            surface: surface.rawValue,
            openID: openID,
            videoSessionID: frame.generation
        )
        restartSurfaceWaiting(baselineSequence: frame.sequence)
    }

    private func rendererLostDisplay() {
        guard isVisible,
              !isSuspended,
              minimumFreshSequence == nil,
              let frame = stream.latestFrame else { return }
        recoverRenderer(after: frame)
    }

    private func restartSurfaceWaiting(baselineSequence: UInt64) {
        guard isVisible, let openID = currentOpenID else { return }
        surfaceAttemptID &+= 1
        let attemptID = surfaceAttemptID
        minimumFreshSequence = baselineSequence
        surfacePrepared = false
        presentationPending = false
        container.beginSurfaceAttempt(attemptID)
        preparationTask?.cancel()
        preparationTask = nil
        presentationTask?.cancel()
        presentationTask = nil
        showPlaybackCover(indicatorDelay: 0.4)
        startSurfacePreparation(openID: openID, attemptID: attemptID)
    }

    private func recoverStreamIfStalled(
        baselineSequence: UInt64,
        openedAt: TimeInterval
    ) {
        guard stream.state == .ready else { return }
        let streamAdvanced = stream.latestSequence > baselineSequence
            && (stream.latestFrame?.decodedAt ?? -.infinity) >= openedAt
        if streamAdvanced {
            restartSurfaceWaiting(baselineSequence: stream.latestSequence)
        } else {
            stream.retryNow()
        }
    }

    private func showPlaybackCover(indicatorDelay: TimeInterval) {
        if coverShownAt == nil {
            coverShownAt = ProcessInfo.processInfo.systemUptime
            DirectStreamTelemetry.record(
                component: "video",
                event: "cover_shown",
                surface: surface.rawValue,
                openID: currentOpenID,
                videoSessionID: stream.latestFrame?.generation
            )
        }
        container.showCover(true, indicatorDelay: indicatorDelay)
    }

    private func hidePlaybackCover() {
        container.showCover(false)
        let elapsed = coverShownAt.map {
            Int((ProcessInfo.processInfo.systemUptime - $0) * 1_000)
        }
        coverShownAt = nil
        DirectStreamTelemetry.record(
            component: "video",
            event: "cover_hidden",
            surface: surface.rawValue,
            openID: currentOpenID,
            videoSessionID: stream.latestFrame?.generation,
            elapsedMilliseconds: elapsed
        )
    }

    private func recordConnectionIndicatorShown() {
        guard isVisible, !connectionIndicatorRecorded else { return }
        connectionIndicatorRecorded = true
        let elapsed = coverShownAt.map {
            Int((ProcessInfo.processInfo.systemUptime - $0) * 1_000)
        }
        DirectStreamTelemetry.record(
            component: "video",
            event: "connection_indicator_shown",
            surface: surface.rawValue,
            openID: currentOpenID,
            videoSessionID: stream.latestFrame?.generation,
            elapsedMilliseconds: elapsed
        )
    }
}

@MainActor
final class CameraVideoContainerView: NSView {
    var onIndicatorShown: (() -> Void)?
    var onRendererLostDisplay: (() -> Void)? {
        didSet { pixelBufferView.onDisplayReadinessLost = onRendererLostDisplay }
    }

    private let pixelBufferView = CameraPixelBufferView()
    private let cover = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Connecting…")
    private var cornerStyle: CameraVideoCornerStyle
    private var indicatorTask: Task<Void, Never>?

    init(cornerStyle: CameraVideoCornerStyle) {
        self.cornerStyle = cornerStyle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        pixelBufferView.autoresizingMask = [.width, .height]
        addSubview(pixelBufferView)

        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.black.cgColor
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        loadingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        loadingLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        loadingLabel.alignment = .center
        cover.addSubview(progressIndicator)
        cover.addSubview(loadingLabel)
        addSubview(cover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var cornerConfiguration: NSViewCornerConfiguration? {
        switch cornerStyle {
        case .square:
            .uniformCorners(radius: .fixed(0))
        case .containerConcentric:
            .uniformCorners(radius: .containerConcentric)
        }
    }

    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        applyCornerRadius()
    }

    override func layout() {
        super.layout()
        applyCornerRadius()
        pixelBufferView.frame = bounds
        cover.frame = bounds
        progressIndicator.sizeToFit()
        progressIndicator.frame.origin = NSPoint(
            x: floor((cover.bounds.width - progressIndicator.frame.width) / 2),
            y: floor((cover.bounds.height - progressIndicator.frame.height) / 2) - 14
        )
        loadingLabel.sizeToFit()
        loadingLabel.frame.origin = NSPoint(
            x: floor((cover.bounds.width - loadingLabel.frame.width) / 2),
            y: progressIndicator.frame.maxY + 9
        )
    }

    func setCornerStyle(_ style: CameraVideoCornerStyle) {
        guard style != cornerStyle else { return }
        cornerStyle = style
        invalidateCornerConfiguration()
    }

    @discardableResult
    func present(_ frame: CameraFrame) -> Bool {
        pixelBufferView.present(frame)
    }

    func clearFrame() {
        pixelBufferView.clear()
    }

    func beginSurfaceAttempt(_ attemptID: UInt64) {
        pixelBufferView.beginSurfaceAttempt(attemptID)
    }

    func prepareForOpen(attemptID: UInt64) async -> Bool {
        await pixelBufferView.prepareForOpen(attemptID: attemptID)
    }

    func presentOpening(_ frame: CameraFrame, attemptID: UInt64) async -> Bool {
        await pixelBufferView.presentOpening(frame, attemptID: attemptID)
    }

    func shutdown() {
        indicatorTask?.cancel()
        indicatorTask = nil
        pixelBufferView.shutdown()
    }

    func showCover(_ show: Bool, animated: Bool = true, indicatorDelay: TimeInterval = 0) {
        indicatorTask?.cancel()
        indicatorTask = nil
        cover.isHidden = !show
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        loadingLabel.isHidden = true
        guard show, animated else { return }
        if indicatorDelay <= 0 {
            showIndicator()
            return
        }
        indicatorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(indicatorDelay))
            guard !Task.isCancelled, let self, !self.cover.isHidden else { return }
            self.showIndicator()
            self.indicatorTask = nil
        }
    }

    private func showIndicator() {
        progressIndicator.isHidden = false
        loadingLabel.isHidden = false
        progressIndicator.startAnimation(nil)
        onIndicatorShown?()
    }

    private func applyCornerRadius() {
        layer?.cornerRadius = effectiveCornerRadii?.topLeft ?? 0
    }
}

@MainActor
private final class CameraPixelBufferView: NSView {
    var onDisplayReadinessLost: (() -> Void)?

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let receiver: AVSampleBufferVideoRenderer.Receiver
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var expectsNotReady = false
    private var readinessObserver: NSObjectProtocol?
    private var currentSurfaceAttemptID: UInt64 = 0

    override init(frame frameRect: NSRect) {
        receiver = synchronizer.sampleBufferReceiver(
            adding: displayLayer.sampleBufferRenderer
        )
        super.init(frame: frameRect)
        wantsLayer = true
        layer = displayLayer
        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = NSColor.black.cgColor
        readinessObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange,
            object: displayLayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.displayReadinessChanged()
            }
        }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present(_ frame: CameraFrame) -> Bool {
        enqueue(frame)
    }

    func shutdown() {
        if let readinessObserver {
            NotificationCenter.default.removeObserver(readinessObserver)
            self.readinessObserver = nil
        }
        onDisplayReadinessLost = nil
    }

    func clear() {}

    func beginSurfaceAttempt(_ attemptID: UInt64) {
        currentSurfaceAttemptID = max(currentSurfaceAttemptID, attemptID)
    }

    func prepareForOpen(attemptID: UInt64) async -> Bool {
        await withExclusiveOperation {
            guard !Task.isCancelled,
                  attemptID == currentSurfaceAttemptID else { return false }
            expectsNotReady = true
            await receiver.flush(removingDisplayedImage: true)
            return !Task.isCancelled && attemptID == currentSurfaceAttemptID
        }
    }

    func presentOpening(_ frame: CameraFrame, attemptID: UInt64) async -> Bool {
        await withExclusiveOperation {
            guard !Task.isCancelled,
                  attemptID == currentSurfaceAttemptID else { return false }
            if !enqueue(frame) {
                expectsNotReady = true
                await receiver.flush(removingDisplayedImage: true)
                guard !Task.isCancelled,
                      attemptID == currentSurfaceAttemptID else { return false }
                guard enqueue(frame) else { return false }
            }
            var acceptedImage = false
            for _ in 0..<100 {
                guard !Task.isCancelled,
                      attemptID == currentSurfaceAttemptID else { return false }
                if displayLayer.isReadyForDisplay {
                    acceptedImage = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            acceptedImage = acceptedImage || displayLayer.isReadyForDisplay
            guard acceptedImage else {
                expectsNotReady = true
                return false
            }

            // isReadyForDisplay means the layer accepted an image, not that
            // WindowServer has composited it. Keep the cover for one display
            // interval so every success path waits for the first paint.
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled,
                  attemptID == currentSurfaceAttemptID,
                  displayLayer.isReadyForDisplay else { return false }
            expectsNotReady = false
            return true
        }
    }

    private func withExclusiveOperation<T>(
        _ operation: () async -> T
    ) async -> T {
        if operationInProgress {
            await withCheckedContinuation { continuation in
                operationWaiters.append(continuation)
            }
        }
        operationInProgress = true
        let result = await operation()
        if operationWaiters.isEmpty {
            operationInProgress = false
        } else {
            operationWaiters.removeFirst().resume()
        }
        return result
    }

    private func displayReadinessChanged() {
        guard !displayLayer.isReadyForDisplay,
              !expectsNotReady else { return }
        recordRendererFailure("ready_for_display_became_false")
        onDisplayReadinessLost?()
    }

    private func enqueue(_ frame: CameraFrame) -> Bool {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription else { return false }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: frame.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
        let sampleBuffer else { return false }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as NSArray?
        if let first = attachments?.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(
            unsafeBuffer: sampleBuffer
        )
        switch receiver.enqueueImmediately(ready) {
        case .enqueued:
            return true
        case let .enqueuedWithDecodeFailures(error):
            recordRendererFailure("decode_failure=\(error)")
        case .cancelledDueToFlush:
            recordRendererFailure("cancelled_due_to_flush")
        case let .cancelledDueToFlushRequiredToResume(reason):
            recordRendererFailure(
                "flush_required=\(reason.map(String.init(describing:)) ?? "unspecified")"
            )
        case let .cancelledDueToError(error):
            recordRendererFailure("error=\(error)")
        @unknown default:
            recordRendererFailure("unknown_enqueue_result")
        }
        return false
    }

    private func recordRendererFailure(_ detail: String) {
        DirectStreamTelemetry.record(
            component: "renderer",
            event: "frame_enqueue_failed",
            detail: detail
        )
    }
}
