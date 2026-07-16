import XCTest
import CamBarCore

final class CamBarTests: XCTestCase {
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

    func testDirectStreamTelemetryRedactsDetail() throws {
        DirectStreamTelemetry.reset()

        DirectStreamTelemetry.record(
            component: "test",
            event: "sample",
            detail: "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101"
        )

        let text = try String(contentsOf: DirectStreamTelemetry.logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("admin:***@192.168.1.249"))
        XCTAssertFalse(text.contains("secret"))
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
