import CamBarCore
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
            DirectStreamTelemetry.record(component: "login_item", event: "enabled")
            return
        case .notRegistered:
            DirectStreamTelemetry.record(component: "login_item", event: "registering")
            register(service)
        case .requiresApproval:
            DirectStreamTelemetry.record(component: "login_item", event: "requires_approval")
            NSLog("CamBar login item requires approval in System Settings > General > Login Items.")
        case .notFound:
            DirectStreamTelemetry.record(component: "login_item", event: "unavailable")
            NSLog("CamBar login item registration is unavailable for this bundle.")
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
