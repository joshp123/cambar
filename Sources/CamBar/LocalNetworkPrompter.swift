import Foundation
import Network

final class LocalNetworkPrompter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CamBar.localnetwork")
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_rtsp._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.stop()
            }
        }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
