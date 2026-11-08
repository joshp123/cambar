import XCTest
import CamBarCore

final class CamBarTests: XCTestCase {
    func testStatusItemHitRegionUsesWindowIdentity() {
        XCTAssertTrue(StatusItemHitRegion.contains(
            screenPoint: CGPoint(x: -10_000, y: -10_000),
            eventWindowNumber: 42,
            statusRect: CGRect(x: 100, y: 100, width: 24, height: 24),
            statusWindowNumber: 42
        ))
    }

    func testStatusItemHitRegionUsesScreenCoordinatesAndTolerance() {
        let rect = CGRect(x: -1200, y: 900, width: 24, height: 24)

        XCTAssertTrue(StatusItemHitRegion.contains(
            screenPoint: CGPoint(x: -1201, y: 912),
            eventWindowNumber: 0,
            statusRect: rect,
            statusWindowNumber: 17
        ))
        XCTAssertFalse(StatusItemHitRegion.contains(
            screenPoint: CGPoint(x: -1203, y: 912),
            eventWindowNumber: 0,
            statusRect: rect,
            statusWindowNumber: 17
        ))
        XCTAssertFalse(StatusItemHitRegion.contains(
            screenPoint: CGPoint(x: -1188, y: 927),
            eventWindowNumber: 0,
            statusRect: rect,
            statusWindowNumber: 17
        ))
    }

    func testStatusClickRemainsSoleCloseIntentWhenMonitorIgnoresHit() {
        var state = PopoverPresentationState()
        XCTAssertEqual(state.toggle(at: 1), .show)
        XCTAssertEqual(state.didShow(), .none)
        XCTAssertTrue(StatusItemHitRegion.contains(
            screenPoint: CGPoint(x: 112, y: 112),
            eventWindowNumber: 0,
            statusRect: CGRect(x: 100, y: 100, width: 24, height: 24),
            statusWindowNumber: 17
        ))

        XCTAssertEqual(state.toggle(at: 2), .close)
        XCTAssertEqual(state.didClose(), .none)
        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.wantsVisible)
    }

    func testPopoverOutsideCloseCannotReopenItself() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.toggle(at: 1), .show)
        XCTAssertEqual(state.didShow(), .none)
        XCTAssertEqual(state.requestClose(at: 2), .close)
        XCTAssertEqual(state.didClose(), .none)
        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.wantsVisible)
    }

    func testPopoverCloseDuringOpeningConvergesClosed() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.toggle(at: 1), .show)
        XCTAssertEqual(state.requestClose(at: 2), .none)
        XCTAssertEqual(state.phase, .opening)
        XCTAssertEqual(state.didShow(), .close)
        XCTAssertEqual(state.didClose(), .none)
        XCTAssertEqual(state.phase, .closed)
    }

    func testPopoverOpenDuringClosingConvergesOpen() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.toggle(at: 1), .show)
        XCTAssertEqual(state.didShow(), .none)
        XCTAssertEqual(state.toggle(at: 2), .close)
        XCTAssertEqual(state.toggle(at: 3), .none)
        XCTAssertEqual(state.didClose(), .show)
        XCTAssertEqual(state.didShow(), .none)
        XCTAssertEqual(state.phase, .open)
    }

    func testPopoverReopenGetsNewPresentationIdentity() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.requestOpen(at: 1), .show)
        let firstPresentation = state.presentationID
        XCTAssertEqual(state.requestClose(at: 2), .none)
        XCTAssertEqual(state.didShow(), .close)
        XCTAssertEqual(state.didClose(), .none)
        XCTAssertEqual(state.requestOpen(at: 3), .show)

        XCTAssertNotEqual(state.presentationID, firstPresentation)
    }

    func testStaleOutsideClickCannotCloseNewerOpenIntent() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.toggle(at: 10), .show)
        XCTAssertEqual(state.didShow(), .none)
        XCTAssertEqual(state.toggle(at: 20), .close)
        XCTAssertEqual(state.didClose(), .none)
        XCTAssertEqual(state.toggle(at: 30), .show)
        XCTAssertEqual(state.requestClose(at: 25), .none)
        XCTAssertTrue(state.wantsVisible)
        XCTAssertEqual(state.phase, .opening)
    }

    func testFailedPresentationStopsWithoutRetrying() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.toggle(at: 1), .show)
        state.presentationFailed()

        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.wantsVisible)
    }

    func testUnexpectedCloseWhileOpenFailsClosed() {
        var state = PopoverPresentationState()
        XCTAssertEqual(state.toggle(at: 1), .show)
        XCTAssertEqual(state.didShow(), .none)

        XCTAssertEqual(state.didClose(), .none)

        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.wantsVisible)
    }

    func testUnexpectedCloseWhileOpeningFailsClosed() {
        var state = PopoverPresentationState()
        XCTAssertEqual(state.toggle(at: 1), .show)

        XCTAssertEqual(state.didClose(), .none)

        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.wantsVisible)
    }

    func testLateDidShowFailsClosed() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.didShow(), .close)
        XCTAssertEqual(state.phase, .closed)
        XCTAssertEqual(state.didClose(), .none)
        XCTAssertEqual(state.didClose(), .none)

        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.wantsVisible)
    }

    func testSpuriousDidShowWithoutDidCloseCannotWedgeNextOpen() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.didShow(), .close)
        XCTAssertEqual(state.toggle(at: 1), .show)

        XCTAssertEqual(state.phase, .opening)
        XCTAssertTrue(state.wantsVisible)
    }

    func testLateDidShowAfterPresentationFailureIsClosed() {
        var state = PopoverPresentationState()

        XCTAssertEqual(state.toggle(at: 1), .show)
        state.presentationFailed()
        XCTAssertEqual(state.didShow(), .close)
        XCTAssertEqual(state.didClose(), .none)

        XCTAssertEqual(state.phase, .closed)
        XCTAssertFalse(state.wantsVisible)
    }

    func testEqualTimestampIsRejectedAsStale() {
        var state = PopoverPresentationState()
        XCTAssertEqual(state.toggle(at: 1), .show)

        XCTAssertEqual(state.requestClose(at: 1), .none)

        XCTAssertTrue(state.wantsVisible)
        XCTAssertEqual(state.phase, .opening)
    }

    func testRedactRtspCredentialsInLogText() {
        let log = "Input #0, rtsp, from 'rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101':"

        let redacted = StreamSourceResolver.redactRtspCredentials(in: log)

        XCTAssertEqual(
            redacted,
            "Input #0, rtsp, from 'rtsp://admin:***@192.168.1.249:554/Streaming/Channels/101':"
        )
        XCTAssertFalse(redacted.contains("secret"))
    }

    func testLoadCameraConfigParsesFirstCamera() throws {
        let yaml = """
        cameras:
          - name: hikvision
            host: 192.168.1.249
            port: 554
            protocol: rtsp
            username: admin
            password: secret
            rtsp_transport: tcp
            stream: Streaming/Channels/101
          - name: second
            host: 10.0.0.10
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("yaml")
        try yaml.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let config = StreamSourceResolver.loadCameraConfig(from: tempURL)

        XCTAssertEqual(config?.name, "hikvision")
        XCTAssertEqual(config?.host, "192.168.1.249")
        XCTAssertEqual(config?.port, 554)
        XCTAssertEqual(config?.protocolName, "rtsp")
        XCTAssertEqual(config?.username, "admin")
        XCTAssertEqual(config?.password, "secret")
        XCTAssertEqual(config?.stream, "Streaming/Channels/101")
    }

    func testLoadCameraConfigAcceptsExpandedListItemAndIgnoresOtherSections() throws {
        let yaml = """
        host: wrong.example
        cameras:
          -
            name: front
            host: camera.local
            port: 8554
            protocol: rtsp
            stream: live
          - name: ignored
            host: ignored.example
        output:
          host: also-wrong.example
        """
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("yaml")
        try yaml.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let config = StreamSourceResolver.loadCameraConfig(from: tempURL)

        XCTAssertEqual(config?.name, "front")
        XCTAssertEqual(config?.host, "camera.local")
        XCTAssertEqual(config?.port, 8554)
    }

    func testBuildRtspURLFromCameraConfig() {
        let config = StreamSourceResolver.CameraConfig(
            name: "hikvision",
            host: "192.168.1.249",
            port: 554,
            protocolName: "rtsp",
            username: "admin",
            password: "secret",
            stream: "Streaming/Channels/101"
        )

        let rtspURL = StreamSourceResolver.buildRtspURL(from: config)

        XCTAssertEqual(rtspURL, "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101")
    }

    func testBuildRtspURLRejectsInvalidInputs() {
        XCTAssertNil(StreamSourceResolver.buildRtspURL(from: .init(host: "camera.local", port: 70_000)))
        XCTAssertNil(StreamSourceResolver.buildRtspURL(from: .init(host: "camera.local", protocolName: "http")))
        XCTAssertNil(StreamSourceResolver.buildRtspURL(from: .init(stream: "https://camera.local/live")))
    }

    func testLoadCameraConfigRejectsMalformedPort() throws {
        let yaml = """
        cameras:
          - name: front
            host: camera.local
            port: nope
        """
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("yaml")
        try yaml.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertNil(StreamSourceResolver.loadCameraConfig(from: tempURL))
    }

    func testCachedFrameMustBeRecentAndNotFromTheFuture() {
        XCTAssertTrue(NativeFrameFreshness.canPresentCachedFrame(now: 10, decodedAt: 9.9))
        XCTAssertFalse(NativeFrameFreshness.canPresentCachedFrame(now: 10, decodedAt: 9.899))
        XCTAssertFalse(NativeFrameFreshness.canPresentCachedFrame(now: 10, decodedAt: 10.001))
    }

    func testFrameCadenceTracksPlausiblePresentationDeltas() {
        XCTAssertEqual(
            NativeFrameCadence.updatedFrameDuration(current: 0.04, presentationDelta: 0.05),
            0.042,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            NativeFrameCadence.updatedFrameDuration(current: 0.04, presentationDelta: 0.5),
            0.04,
            accuracy: 0.000_001
        )
    }

    func testFrameCadenceUsesOneBoundedFrameOfLead() {
        XCTAssertEqual(NativeFrameCadence.presentationLead(frameDuration: 0.04), 0.04)
        XCTAssertEqual(
            NativeFrameCadence.presentationLead(frameDuration: 0.001),
            NativeFrameCadence.minimumFrameDuration
        )
        XCTAssertEqual(NativeFrameCadence.presentationLead(frameDuration: 0.1), 0.05)
    }

    func testFrameCadenceReanchorsOnlyForMissingOrBrokenTimeline() {
        XCTAssertTrue(NativeFrameCadence.requiresReanchor(
            presentationTime: 10,
            previousPresentationTime: nil,
            targetDisplayTime: nil,
            now: 20,
            consecutiveLateFrames: 0
        ))
        XCTAssertFalse(NativeFrameCadence.requiresReanchor(
            presentationTime: 10.04,
            previousPresentationTime: 10,
            targetDisplayTime: 20.04,
            now: 20,
            consecutiveLateFrames: 0
        ))
        XCTAssertTrue(NativeFrameCadence.requiresReanchor(
            presentationTime: 10,
            previousPresentationTime: 10,
            targetDisplayTime: 20.04,
            now: 20,
            consecutiveLateFrames: 0
        ))
        XCTAssertTrue(NativeFrameCadence.requiresReanchor(
            presentationTime: 11,
            previousPresentationTime: 10,
            targetDisplayTime: 21,
            now: 20,
            consecutiveLateFrames: 0
        ))
        XCTAssertFalse(NativeFrameCadence.requiresReanchor(
            presentationTime: 10.04,
            previousPresentationTime: 10,
            targetDisplayTime: 19.9,
            now: 20,
            consecutiveLateFrames: 0
        ))
        XCTAssertFalse(NativeFrameCadence.requiresReanchor(
            presentationTime: 10.12,
            previousPresentationTime: 10,
            targetDisplayTime: 20.12,
            now: 20,
            consecutiveLateFrames: 0
        ))
        XCTAssertTrue(NativeFrameCadence.requiresReanchor(
            presentationTime: 10.16,
            previousPresentationTime: 10.12,
            targetDisplayTime: 20.6,
            now: 20,
            consecutiveLateFrames: 0
        ))
        XCTAssertTrue(NativeFrameCadence.requiresReanchor(
            presentationTime: 10.04,
            previousPresentationTime: 10,
            targetDisplayTime: 19.9,
            now: 20,
            consecutiveLateFrames: 2
        ))
        XCTAssertTrue(NativeFrameCadence.isLate(targetDisplayTime: 19.9, now: 20))
    }

    func testOpeningWaitsForAFrameDecodedAfterTheClick() {
        XCTAssertTrue(NativeFrameFreshness.isPostOpenFrame(
            sequence: 42,
            baselineSequence: 41,
            decodedAt: 10.001,
            openedAt: 10
        ))
        XCTAssertFalse(NativeFrameFreshness.isPostOpenFrame(
            sequence: 41,
            baselineSequence: 41,
            decodedAt: 10.001,
            openedAt: 10
        ))
        XCTAssertFalse(NativeFrameFreshness.isPostOpenFrame(
            sequence: 42,
            baselineSequence: 41,
            decodedAt: 9.999,
            openedAt: 10
        ))
    }

    func testNativeRetryPolicyIsFastThenBacksOffToAMinute() {
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 1), 0.1)
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 4), 5)
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 8), 60)
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 500), 60)
    }

    func testCameraIsOnTheLocalNetworkOnlyInsideTheInterfaceSubnet() {
        let homeWiFi = IPv4Network(address: IPv4Network.parse("192.168.1.130")!, prefixLength: 24)
        XCTAssertTrue(homeWiFi.contains("192.168.1.249"))
        XCTAssertFalse(homeWiFi.contains("192.168.2.249"))
        XCTAssertFalse(homeWiFi.contains("camera.local"))
        let mobileNetwork = IPv4Network(address: IPv4Network.parse("192.0.0.2")!, prefixLength: 32)
        XCTAssertFalse(mobileNetwork.contains("192.168.1.249"))
    }

    func testCameraLoginGoesOnlyToAProvenCameraOrThroughTailscale() {
        let checks: [CameraRoutePolicy.LocalCheck] = [
            .notOnLocalNetwork, .certificateNotLearned, .otherDevice, .noAnswer,
        ]
        for check in checks {
            XCTAssertEqual(CameraRoutePolicy.decide(hostIsIPv4Address: true, localCheck: check, tailscaleConnected: true).decision, .tailscale)
            XCTAssertEqual(CameraRoutePolicy.decide(hostIsIPv4Address: true, localCheck: check, tailscaleConnected: false).decision, .unavailable)
        }
        XCTAssertEqual(CameraRoutePolicy.decide(hostIsIPv4Address: true, localCheck: .proven, tailscaleConnected: false).decision, .direct)
        XCTAssertEqual(CameraRoutePolicy.decide(hostIsIPv4Address: true, localCheck: .proven, tailscaleConnected: true).decision, .direct)
        XCTAssertEqual(CameraRoutePolicy.decide(hostIsIPv4Address: false, localCheck: .notOnLocalNetwork, tailscaleConnected: false).decision, .systemRouting)
    }

    func testTailscaleAddressesAreRecognised() {
        XCTAssertTrue(TailscaleAddress.isTailscale(IPv4Network(address: IPv4Network.parse("100.117.45.44")!, prefixLength: 32)))
        XCTAssertFalse(TailscaleAddress.isTailscale(IPv4Network(address: IPv4Network.parse("100.128.0.1")!, prefixLength: 32)))
        XCTAssertFalse(TailscaleAddress.isTailscale(IPv4Network(address: IPv4Network.parse("192.168.1.130")!, prefixLength: 24)))
    }

    func testAVCCPacketizerRestoresLengthPrefixesExactlyOnce() {
        let packet = AVCCPacketizer.packetize([
            Data([0x65, 0xAA, 0xBB]),
            Data(),
            Data([0x41, 0xCC]),
        ], codec: .h264)
        XCTAssertEqual(packet, Data([
            0, 0, 0, 3, 0x65, 0xAA, 0xBB,
            0, 0, 0, 2, 0x41, 0xCC,
        ]))
    }

    func testAVCCPacketizerDropsNonPictureH264NALUnits() {
        let packet = AVCCPacketizer.packetize([
            Data([0x06, 0x01]),
            Data([0x67, 0x02]),
            Data([0x68, 0x03]),
            Data([0x09, 0x04]),
            Data([0x65, 0x05]),
        ], codec: .h264)
        XCTAssertEqual(packet, Data([0, 0, 0, 2, 0x65, 0x05]))
    }

    func testStreamStaysWarmUnlessLowPowerModeAndNobodyIsLooking() {
        XCTAssertTrue(StreamWarmthPolicy.shouldStream(appStarted: true, asleep: false, lowPowerMode: false, viewed: false))
        XCTAssertFalse(StreamWarmthPolicy.shouldStream(appStarted: true, asleep: false, lowPowerMode: true, viewed: false))
        XCTAssertTrue(StreamWarmthPolicy.shouldStream(appStarted: true, asleep: false, lowPowerMode: true, viewed: true))
        XCTAssertFalse(StreamWarmthPolicy.shouldStream(appStarted: true, asleep: true, lowPowerMode: false, viewed: true))
        XCTAssertFalse(StreamWarmthPolicy.shouldStream(appStarted: false, asleep: false, lowPowerMode: false, viewed: false))
    }

    func testCachedFramesAreOnlyReplayedWhileReceptionIsCurrent() {
        XCTAssertTrue(NativeFrameFreshness.canReplayCachedFrames(now: 10, lastReceivedAt: 9.5))
        XCTAssertFalse(NativeFrameFreshness.canReplayCachedFrames(now: 10, lastReceivedAt: 8.9))
        XCTAssertFalse(NativeFrameFreshness.canReplayCachedFrames(now: 10, lastReceivedAt: nil))
    }

    func testLagTrackerAccumulatesASmallSustainedShortage() {
        var tracker = RealTimeLagTracker()
        for _ in 0..<6 {  // 30 s at 90% of real time
            tracker.add(wallSeconds: 5, mediaSeconds: 4.5)
        }
        XCTAssertEqual(tracker.secondsBehind, 3, accuracy: 0.01)
    }

    func testLagTrackerIgnoresJitterOnAHealthyStream() {
        var tracker = RealTimeLagTracker()
        for window in 0..<10_000 {  // Frames landing either side of a boundary.
            tracker.add(wallSeconds: 5, mediaSeconds: window.isMultiple(of: 2) ? 4.7 : 5.3)
        }
        XCTAssertLessThan(tracker.secondsBehind, 0.5)
    }

    func testLagTrackerRecoversWhenABacklogDrains() {
        var tracker = RealTimeLagTracker()
        tracker.add(wallSeconds: 5, mediaSeconds: 3)
        XCTAssertEqual(tracker.secondsBehind, 2, accuracy: 0.01)
        tracker.add(wallSeconds: 5, mediaSeconds: 7)
        XCTAssertEqual(tracker.secondsBehind, 0, accuracy: 0.01)
    }

    func testLagTrackerAbsorbsClockDriftOnAWeekLongStream() {
        var tracker = RealTimeLagTracker()
        let windowsInAWeek = 7 * 24 * 720
        for _ in 0..<windowsInAWeek {  // Camera clock 50 ppm slow.
            tracker.add(wallSeconds: 5, mediaSeconds: 5 * 0.99995)
        }
        XCTAssertEqual(tracker.secondsBehind, 0, accuracy: 0.01)
    }

    func testFallbackIsTheHikvisionSubstreamOfTheMainStream() {
        XCTAssertEqual(
            StreamSourceResolver.fallbackRtspURL(forMain: "rtsp://u:p@cam:554/Streaming/Channels/101"),
            "rtsp://u:p@cam:554/Streaming/Channels/102"
        )
        XCTAssertNil(StreamSourceResolver.fallbackRtspURL(forMain: "rtsp://cam/Streaming/Channels/102"))
        XCTAssertNil(StreamSourceResolver.fallbackRtspURL(forMain: "rtsp://cam/live"))
    }

    func testAVCCPacketizerDropsH265ParameterSetsAndKeepsSlices() {
        // NAL type is bits 1-6 of the first header byte.
        let packet = AVCCPacketizer.packetize([
            Data([32 << 1, 0x01, 0xAA]),  // VPS
            Data([33 << 1, 0x01, 0xBB]),  // SPS
            Data([34 << 1, 0x01, 0xCC]),  // PPS
            Data([39 << 1, 0x01, 0xDD]),  // prefix SEI
            Data([19 << 1, 0x01, 0xEE]),  // IDR slice
            Data([1 << 1, 0x01, 0xFF]),   // trailing slice
        ], codec: .h265)
        XCTAssertEqual(packet, Data([
            0, 0, 0, 3, 19 << 1, 0x01, 0xEE,
            0, 0, 0, 3, 1 << 1, 0x01, 0xFF,
        ]))
    }
}
