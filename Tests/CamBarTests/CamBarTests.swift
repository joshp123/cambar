import XCTest
import CamBarCore

final class CamBarTests: XCTestCase {
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

    func testRelayHealthRequiresCurrentVideoFlow() throws {
        let first = try XCTUnwrap(RelayStreamSample.decode(Data(#"{"producers":[{"medias":["video, recvonly, H264"],"bytes_recv":400000}]}"#.utf8)))
        let advancing = try XCTUnwrap(RelayStreamSample.decode(Data(#"{"producers":[{"medias":["video, recvonly, H264"],"bytes_recv":425000}]}"#.utf8)))
        let stalled = try XCTUnwrap(RelayStreamSample.decode(Data(#"{"producers":[{"medias":["video, recvonly, H264"],"bytes_recv":400000}]}"#.utf8)))
        let audioOnly = try XCTUnwrap(RelayStreamSample.decode(Data(#"{"producers":[{"medias":["audio, recvonly, PCMA"],"bytes_recv":425000}]}"#.utf8)))

        XCTAssertTrue(advancing.isAdvancing(from: first))
        XCTAssertFalse(stalled.isAdvancing(from: first))
        XCTAssertFalse(audioOnly.isAdvancing(from: first))
    }

    func testRelayRetryPolicyBacksOffAndCaps() {
        let policy = RelayRetryPolicy()

        XCTAssertEqual(policy.delay(afterFailure: 1), 1)
        XCTAssertEqual(policy.delay(afterFailure: 2), 2)
        XCTAssertEqual(policy.delay(afterFailure: 3), 5)
        XCTAssertEqual(policy.delay(afterFailure: 4), 10)
        XCTAssertEqual(policy.delay(afterFailure: 5), 30)
        XCTAssertEqual(policy.delay(afterFailure: 20), 30)
    }
}
