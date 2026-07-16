import CamBarCore
import Foundation
import ServiceManagement

@MainActor
final class LoginItemController {
    func ensureRegistered() {
        let canonicalURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/CamBar.app")
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let runningURL = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard runningURL == canonicalURL else {
            DirectStreamTelemetry.record(component: "login_item", event: "skipped_noncanonical_bundle")
            return
        }

        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            DirectStreamTelemetry.record(component: "login_item", event: "enabled")
            return
        case .notRegistered, .notFound:
            DirectStreamTelemetry.record(component: "login_item", event: "registering")
            register(service)
        case .requiresApproval:
            DirectStreamTelemetry.record(component: "login_item", event: "requires_approval")
            NSLog("CamBar login item requires approval in System Settings > General > Login Items.")
        @unknown default:
            DirectStreamTelemetry.record(component: "login_item", event: "unknown_status")
            NSLog("CamBar login item registration has an unknown status.")
        }
    }

    private func register(_ service: SMAppService) {
        do {
            try service.register()
            DirectStreamTelemetry.record(component: "login_item", event: "registered")
            NSLog("CamBar login item registered.")
        } catch {
            DirectStreamTelemetry.record(
                component: "login_item",
                event: "registration_failed",
                detail: error.localizedDescription
            )
            NSLog("CamBar login item registration failed: \(error.localizedDescription)")
        }
    }
}
