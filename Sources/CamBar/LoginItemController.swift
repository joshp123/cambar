import Foundation
import ServiceManagement

@MainActor
final class LoginItemController {
    func ensureRegistered() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }

        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            return
        case .notRegistered:
            register(service)
        case .requiresApproval:
            NSLog("CamBar login item requires approval in System Settings > General > Login Items.")
        case .notFound:
            NSLog("CamBar login item registration is unavailable for this bundle.")
        @unknown default:
            NSLog("CamBar login item registration has an unknown status.")
        }
    }

    private func register(_ service: SMAppService) {
        do {
            try service.register()
            NSLog("CamBar login item registered.")
        } catch {
            NSLog("CamBar login item registration failed: \(error.localizedDescription)")
        }
    }
}
