import XCTest
import CamBarCore

final class CamBarTests: XCTestCase {
    func testDerivePreviewRTSPURLFromMainChannel() {
        let main = "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101"

        let preview = StreamSourceResolver.derivePreviewRTSPURL(from: main)

        XCTAssertEqual(preview, "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/102")
    }

    func testSelectRTSPURLFallsBackToMainWhenPreviewUnavailable() {
        let main = "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101"

        let selected = StreamSourceResolver.selectRTSPURL(
            primary: main,
            requestedVariant: .preview,
            previewStreamKnownUnavailable: true
        )

        XCTAssertEqual(selected.url, main)
        XCTAssertEqual(selected.variant, .main)
    }

    func testMaskRtspURLHidesPassword() {
        let raw = "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101"

        let masked = StreamSourceResolver.maskRtspURL(raw)

        XCTAssertEqual(masked, "rtsp://admin:***@192.168.1.249:554/Streaming/Channels/101")
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
        XCTAssertEqual(config?.rtspTransport, "tcp")
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
            rtspTransport: "tcp",
            stream: "Streaming/Channels/101"
        )

        let rtspURL = StreamSourceResolver.buildRtspURL(from: config)

        XCTAssertEqual(rtspURL, "rtsp://admin:secret@192.168.1.249:554/Streaming/Channels/101")
    }
}
