import Foundation
import Network
import Testing

@testable import IPCamKit

@Test("abort immediately cancels a silent pre-PLAY session")
func abortCancelsSilentStartup() async throws {
  let listener = try NWListener(using: .tcp, on: .any)
  let queue = DispatchQueue(label: "ipcamkit.abort-test")
  listener.newConnectionHandler = { connection in
    connection.start(queue: queue)
  }
  listener.start(queue: queue)
  defer { listener.cancel() }

  while listener.port == nil {
    try await Task.sleep(for: .milliseconds(1))
  }
  let session = RTSPClientSession(
    url: "rtsp://127.0.0.1:\(listener.port!.rawValue)/silent",
    transport: .tcp
  )
  let startup = Task { try await session.start() }
  try await Task.sleep(for: .milliseconds(50))

  let started = ContinuousClock.now
  await session.abort()
  let elapsed = started.duration(to: .now)
  #expect(elapsed < .milliseconds(100))

  do {
    _ = try await startup.value
    Issue.record("silent startup unexpectedly succeeded")
  } catch {
    // Closing the socket must release the pending start request.
  }
}
