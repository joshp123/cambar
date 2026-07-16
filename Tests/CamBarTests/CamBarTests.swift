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

    func testMaskRtspURLHidesPassword() {
        let raw = "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101"

        let masked = StreamSourceResolver.maskRtspURL(raw)

        XCTAssertEqual(masked, "rtsp://admin:***@192.168.1.249:554/Streaming/Channels/101")
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

    func testNativeRetryPolicyIsFastThenBounded() {
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 1), 0.1)
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 2), 0.5)
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 3), 2)
        XCTAssertEqual(NativeStreamRetryPolicy.delay(afterFailure: 20), 5)
    }

    func testH264PacketLossForcesDiscontinuityRecovery() {
        XCTAssertFalse(H264StreamContinuity.isDiscontinuous(packetLoss: 0))
        XCTAssertTrue(H264StreamContinuity.isDiscontinuous(packetLoss: 1))
    }

    func testAVCCPacketizerRestoresLengthPrefixesExactlyOnce() {
        let packet = AVCCPacketizer.packetizeH264Video([
            Data([0x65, 0xAA, 0xBB]),
            Data(),
            Data([0x41, 0xCC]),
        ])
        XCTAssertEqual(packet, Data([
            0, 0, 0, 3, 0x65, 0xAA, 0xBB,
            0, 0, 0, 2, 0x41, 0xCC,
        ]))
    }

    func testAVCCPacketizerDropsNonPictureH264NALUnits() {
        let packet = AVCCPacketizer.packetizeH264Video([
            Data([0x06, 0x01]),
            Data([0x67, 0x02]),
            Data([0x68, 0x03]),
            Data([0x09, 0x04]),
            Data([0x65, 0x05]),
        ])
        XCTAssertEqual(packet, Data([0, 0, 0, 2, 0x65, 0x05]))
    }
}
