import AppKit

if let probeIndex = CommandLine.arguments.firstIndex(of: "--probe") {
    let secondsArgument = CommandLine.arguments.dropFirst(probeIndex + 1).first
    HeadlessStreamProbe.run(seconds: secondsArgument.flatMap(TimeInterval.init) ?? 10)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
