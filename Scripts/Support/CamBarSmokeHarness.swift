import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private let appBundleIdentifier = "com.cambar"
private let statusItemIdentifier = "com.cambar.status-item"
private let telemetryURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/CamBar/direct/direct-stream-events.jsonl")

private struct Options {
    var warmCycles = 3
    var screenshotPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/smoke-ui-popover.png").path

    static func parse() throws -> Self {
        var result = Self()
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--warm-cycles":
                guard let value = arguments.first, let count = Int(value), count >= 1 else {
                    throw SmokeError.message("--warm-cycles requires an integer of at least 1")
                }
                result.warmCycles = count
                arguments.removeFirst()
            case "--screenshot":
                guard let value = arguments.first, !value.isEmpty else {
                    throw SmokeError.message("--screenshot requires a path")
                }
                result.screenshotPath = NSString(string: value).expandingTildeInPath
                arguments.removeFirst()
            case "-h", "--help":
                print("Usage: smoke_ui.sh [--warm-cycles COUNT] [--screenshot PATH]")
                exit(0)
            default:
                throw SmokeError.message("unknown argument: \(argument)")
            }
        }
        return result
    }
}

private enum SmokeError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message): message
        }
    }
}

private struct FrontmostApplication {
    let processIdentifier: pid_t
    let name: String

    static func capture() throws -> Self {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw SmokeError.message("could not identify the frontmost application")
        }
        return Self(
            processIdentifier: application.processIdentifier,
            name: application.localizedName ?? application.bundleIdentifier ?? "unknown"
        )
    }

    func assertUnchanged(_ context: String) throws {
        guard let current = NSWorkspace.shared.frontmostApplication else {
            throw SmokeError.message("frontmost application disappeared \(context)")
        }
        guard current.processIdentifier == processIdentifier else {
            let currentName = current.localizedName ?? current.bundleIdentifier ?? "unknown"
            throw SmokeError.message(
                "focus was stolen \(context): expected \(name), found \(currentName)"
            )
        }
    }
}

private struct TelemetryEvent: Decodable {
    let sessionID: String
    let component: String
    let event: String
    let surface: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case component
        case event
        case surface
    }
}

private final class TelemetryReader {
    private let decoder = JSONDecoder()
    private(set) var sessionID: String?

    func latestLaunchSession() throws -> String? {
        try allEvents().last(where: { $0.component == "app" && $0.event == "launch" })?.sessionID
    }

    func waitForLaunch(excluding previousSession: String?, timeout: TimeInterval) throws {
        try wait(timeout: timeout, description: "fresh launch telemetry") { events in
            guard let launch = events.last(where: {
                $0.component == "app"
                    && $0.event == "launch"
                    && $0.sessionID != previousSession
            }) else {
                return false
            }
            self.sessionID = launch.sessionID
            return true
        }
    }

    func events() throws -> [TelemetryEvent] {
        guard let sessionID else { return [] }
        return try allEvents().filter { $0.sessionID == sessionID }
    }

    func count(_ event: String, component: String? = nil, surface: String? = nil) throws -> Int {
        try events().filter {
            $0.event == event
                && (component == nil || $0.component == component)
                && (surface == nil || $0.surface == surface)
        }.count
    }

    func waitForCount(
        _ event: String,
        count expected: Int,
        timeout: TimeInterval,
        component: String? = nil,
        surface: String? = nil
    ) throws {
        try wait(timeout: timeout, description: "\(event) count \(expected)") { _ in
            try self.count(event, component: component, surface: surface) >= expected
        }
    }

    func assertNoFailures() throws {
        for forbidden in ["recover", "black_frame_suspected", "frame_sample_failed"] {
            let matches = try count(forbidden, surface: "menu")
            guard matches == 0 else {
                throw SmokeError.message("telemetry recorded \(matches) \(forbidden) event(s)")
            }
        }
    }

    private func wait(
        timeout: TimeInterval,
        description: String,
        predicate: ([TelemetryEvent]) throws -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let events = try allEvents()
            if try predicate(events) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw SmokeError.message("timed out waiting for \(description)")
    }

    private func allEvents() throws -> [TelemetryEvent] {
        guard FileManager.default.fileExists(atPath: telemetryURL.path) else { return [] }
        let contents = try String(contentsOf: telemetryURL, encoding: .utf8)
        return contents.split(separator: "\n").compactMap { line in
            try? decoder.decode(TelemetryEvent.self, from: Data(line.utf8))
        }
    }
}

private final class StatusItemDriver {
    private let processIdentifier: pid_t

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    func waitForFrame(timeout: TimeInterval) throws -> CGRect {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = findStatusItem(), let frame = frame(of: element), !frame.isEmpty {
                return frame
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        throw SmokeError.message("could not locate AX identifier \(statusItemIdentifier)")
    }

    func click(frame: CGRect) throws {
        let originalLocation = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        defer { CGWarpMouseCursorPosition(originalLocation) }

        let target = CGPoint(x: frame.midX, y: frame.midY)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left) else {
            throw SmokeError.message("could not construct Quartz mouse events")
        }
        moved.post(tap: .cghidEventTap)
        usleep(30_000)
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        usleep(40_000)
    }

    private func findStatusItem() -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var queue: [(AXUIElement, Int)] = [(application, 0)]
        var visited = Set<CFHashCode>()
        var inspected = 0

        while !queue.isEmpty, inspected < 2_000 {
            let (element, depth) = queue.removeFirst()
            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { continue }
            inspected += 1

            if stringAttribute(kAXIdentifierAttribute as String, of: element) == statusItemIdentifier {
                return element
            }
            guard depth < 12 else { continue }
            for attribute in [
                kAXChildrenAttribute as String,
                kAXMenuBarAttribute as String,
                kAXExtrasMenuBarAttribute as String,
                kAXWindowsAttribute as String,
            ] {
                queue.append(contentsOf: elementsAttribute(attribute, of: element).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func elementsAttribute(_ attribute: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return []
        }
        if let elements = value as? [AXUIElement] { return elements }
        if let element = value as! AXUIElement? { return [element] }
        return []
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }
}

private func runProcess(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if !allowFailure, process.terminationStatus != 0 {
        throw SmokeError.message("command failed: \(executable) \(arguments.joined(separator: " "))")
    }
}

private final class OwnedProcesses {
    private let appURL: URL
    private let pidFileURL: URL
    private(set) var appPID: pid_t?
    private var helperPIDs = Set<pid_t>()

    init(appURL: URL, pidFileURL: URL) {
        self.appURL = appURL
        self.pidFileURL = pidFileURL
    }

    func registerApp(_ application: NSRunningApplication) throws {
        let pid = application.processIdentifier
        let expectedPath = appURL.appendingPathComponent("Contents/MacOS/CamBar").standardizedFileURL.path
        guard processPath(pid) == expectedPath else {
            throw SmokeError.message("launched CamBar PID \(pid) has an unexpected executable path")
        }
        appPID = pid
        try writePIDFile()
    }

    func waitForHelper(timeout: TimeInterval) throws {
        guard let appPID else { throw SmokeError.message("CamBar PID was not registered") }
        let expectedPath = appURL.appendingPathComponent("Contents/Resources/bin/go2rtc").standardizedFileURL.path
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = directChildren(of: appPID).filter { processPath($0) == expectedPath }
            if !matches.isEmpty {
                helperPIDs.formUnion(matches)
                try writePIDFile()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw SmokeError.message("bundled go2rtc did not appear as a direct CamBar child")
    }

    func refreshHelpers() throws {
        guard let appPID else { return }
        let expectedPath = appURL.appendingPathComponent("Contents/Resources/bin/go2rtc").standardizedFileURL.path
        helperPIDs.formUnion(directChildren(of: appPID).filter { processPath($0) == expectedPath })
        try writePIDFile()
    }

    func terminate() {
        try? refreshHelpers()
        if let appPID,
           processPath(appPID) == appExecutablePath,
           let application = NSRunningApplication(processIdentifier: appPID) {
            application.terminate()
        }
        usleep(500_000)
        let verifiedHelpers = helperPIDs.filter { processPath($0) == helperExecutablePath }
        let verifiedApp: pid_t? = if let appPID, processPath(appPID) == appExecutablePath {
            appPID
        } else {
            nil
        }
        let pids = Set(verifiedHelpers).union(verifiedApp.map { [$0] } ?? [])
        for pid in pids {
            Darwin.kill(pid, SIGTERM)
        }
        usleep(200_000)
        for pid in pids where processPath(pid) == appExecutablePath || processPath(pid) == helperExecutablePath {
            Darwin.kill(pid, SIGKILL)
        }
    }

    private var appExecutablePath: String {
        appURL.appendingPathComponent("Contents/MacOS/CamBar").standardizedFileURL.path
    }

    private var helperExecutablePath: String {
        appURL.appendingPathComponent("Contents/Resources/bin/go2rtc").standardizedFileURL.path
    }

    private func writePIDFile() throws {
        var lines: [String] = []
        if let appPID {
            lines.append("app \(appPID) 0")
        }
        for helperPID in helperPIDs.sorted() {
            lines.append("helper \(helperPID) \(appPID ?? 0)")
        }
        let contents = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try contents.write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func directChildren(of parentPID: pid_t) -> [pid_t] {
        let requiredCount = proc_listchildpids(parentPID, nil, 0)
        guard requiredCount > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(requiredCount) + 8)
        let count = proc_listchildpids(
            parentPID,
            &children,
            Int32(children.count * MemoryLayout<pid_t>.size)
        )
        guard count > 0 else { return [] }
        return Array(children.prefix(min(Int(count), children.count))).filter { $0 > 0 }
    }

    private func processPath(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

private func runningCamBar(appURL: URL) -> NSRunningApplication? {
    let expectedExecutable = appURL.appendingPathComponent("Contents/MacOS/CamBar").standardizedFileURL
    return NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier).first {
        $0.executableURL?.standardizedFileURL == expectedExecutable
    }
}

private func waitForCamBar(appURL: URL, timeout: TimeInterval) throws -> NSRunningApplication {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let application = runningCamBar(appURL: appURL), !application.isTerminated {
            return application
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    throw SmokeError.message("CamBar did not launch")
}

private func capturePopoverScreenshot(processIdentifier: pid_t, path: String) throws {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else {
        throw SmokeError.message("window inventory unavailable; cannot capture required screenshot")
    }
    let candidates: [(id: CGWindowID, area: CGFloat)] = windows.compactMap { window in
        guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
              ownerPID == Int(processIdentifier),
              let number = window[kCGWindowNumber as String] as? CGWindowID,
              let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width >= 300,
              bounds.height >= 150 else { return nil }
        return (number, bounds.width * bounds.height)
    }
    guard let window = candidates.max(by: { $0.area < $1.area }) else {
        throw SmokeError.message("popover window not found for required screenshot")
    }
    let outputURL = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let captureStartedAt = Date()
    try runProcess("/usr/sbin/screencapture", ["-x", "-l", String(window.id), outputURL.path])
    let values = try outputURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    guard let modifiedAt = values.contentModificationDate,
          modifiedAt >= captureStartedAt.addingTimeInterval(-1),
          (values.fileSize ?? 0) > 0 else {
        throw SmokeError.message("required popover screenshot was not freshly written")
    }
    let darkRatio = try centralDarkPixelRatio(at: outputURL)
    guard darkRatio <= 0.98 else {
        throw SmokeError.message(
            String(format: "composited popover screenshot is effectively black (dark_ratio=%.4f)", darkRatio)
        )
    }
    print(String(format: "Screenshot: %@ (central dark_ratio=%.4f)", outputURL.path, darkRatio))
}

private func centralDarkPixelRatio(at url: URL) throws -> Double {
    guard let image = NSImage(contentsOf: url),
          let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw SmokeError.message("required popover screenshot could not be decoded")
    }
    let crop = CGRect(
        x: CGFloat(source.width) * 0.1,
        y: CGFloat(source.height) * 0.1,
        width: CGFloat(source.width) * 0.8,
        height: CGFloat(source.height) * 0.8
    ).integral
    guard let centralImage = source.cropping(to: crop) else {
        throw SmokeError.message("could not crop the required popover screenshot")
    }
    let width = 64
    let height = 36
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw SmokeError.message("could not create screenshot analysis context")
    }
    context.interpolationQuality = .medium
    context.draw(centralImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var darkPixels = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        if max(pixels[index], pixels[index + 1], pixels[index + 2]) < 16 {
            darkPixels += 1
        }
    }
    return Double(darkPixels) / Double(width * height)
}

private func assertExactCounts(
    telemetry: TelemetryReader,
    opens: Int,
    closes: Int
) throws {
    let expectations: [(String, Int)] = [
        ("status_click", opens + closes),
        ("menu_open_requested", opens),
        ("presentation_started", opens),
        ("live_view", opens),
        ("frame_sample", opens),
        ("menu_closed", closes),
    ]
    for (event, expected) in expectations {
        let actual = try telemetry.count(event, surface: "menu")
        guard actual == expected else {
            throw SmokeError.message("expected exactly \(expected) \(event) event(s), found \(actual)")
        }
    }
    try telemetry.assertNoFailures()
}

private func run() throws {
    let options = try Options.parse()
    let appURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/CamBar.app")
    guard FileManager.default.fileExists(atPath: appURL.path) else {
        throw SmokeError.message("CamBar is not installed at \(appURL.path)")
    }
    guard AXIsProcessTrusted() else {
        throw SmokeError.message(
            "Accessibility permission is required for the terminal running Scripts/smoke_ui.sh"
        )
    }
    guard runningCamBar(appURL: appURL) == nil else {
        throw SmokeError.message("CamBar is already running; refusing to disturb it")
    }
    guard let pidFilePath = ProcessInfo.processInfo.environment["CAMBAR_SMOKE_PID_FILE"],
          !pidFilePath.isEmpty else {
        throw SmokeError.message("CAMBAR_SMOKE_PID_FILE is required; run through Scripts/smoke_ui.sh")
    }

    let originalCursor = CGEvent(source: nil)?.location
    let frontmost = try FrontmostApplication.capture()
    let ownership = OwnedProcesses(appURL: appURL, pidFileURL: URL(fileURLWithPath: pidFilePath))
    defer {
        if let originalCursor { CGWarpMouseCursorPosition(originalCursor) }
        ownership.terminate()
    }

    let telemetry = TelemetryReader()
    let previousTelemetrySession = try telemetry.latestLaunchSession()
    try runProcess("/usr/bin/open", ["-g", "-j", "-n", appURL.path])
    let application = try waitForCamBar(appURL: appURL, timeout: 10)
    try ownership.registerApp(application)
    try ownership.waitForHelper(timeout: 10)
    try telemetry.waitForLaunch(excluding: previousTelemetrySession, timeout: 10)
    try frontmost.assertUnchanged("after background launch")

    let driver = StatusItemDriver(processIdentifier: application.processIdentifier)
    let statusFrame = try driver.waitForFrame(timeout: 10)
    let totalOpenCycles = 1 + options.warmCycles

    for cycle in 1...totalOpenCycles {
        let phase = cycle == 1 ? "cold" : "warm \(cycle - 1)/\(options.warmCycles)"
        let statusClicksBeforeOpen = try telemetry.count("status_click", surface: "menu")
        try driver.click(frame: statusFrame)
        try telemetry.waitForCount(
            "status_click",
            count: statusClicksBeforeOpen + 1,
            timeout: 2,
            component: "app",
            surface: "menu"
        )
        try telemetry.waitForCount("menu_open_requested", count: cycle, timeout: 3, surface: "menu")
        try telemetry.waitForCount("live_view", count: cycle, timeout: 12, surface: "menu")
        try telemetry.waitForCount("frame_sample", count: cycle, timeout: 2, surface: "menu")
        try telemetry.assertNoFailures()
        try frontmost.assertUnchanged("after \(phase) open")
        if cycle == 1 {
            try capturePopoverScreenshot(processIdentifier: application.processIdentifier, path: options.screenshotPath)
        }

        let statusClicksBeforeClose = try telemetry.count("status_click", surface: "menu")
        try driver.click(frame: statusFrame)
        try telemetry.waitForCount(
            "status_click",
            count: statusClicksBeforeClose + 1,
            timeout: 2,
            component: "app",
            surface: "menu"
        )
        try telemetry.waitForCount("menu_closed", count: cycle, timeout: 3, surface: "menu")
        try telemetry.assertNoFailures()
        try ownership.refreshHelpers()
        try frontmost.assertUnchanged("after \(phase) close")
        print("PASS: \(phase) open/live-frame/close")
    }

    try assertExactCounts(telemetry: telemetry, opens: totalOpenCycles, closes: totalOpenCycles)
    try frontmost.assertUnchanged("at completion")
    print("PASS: \(totalOpenCycles) open/close cycles, exact click intents, no recovery or black-frame telemetry")
}

do {
    try run()
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
