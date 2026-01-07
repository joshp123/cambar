import SwiftUI

struct SettingsView: View {
    @AppStorage("rtspURL") private var rtspURL: String = ""
    @Environment(\.dismiss) private var dismiss
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Camera")
                    .font(.headline)
                TextField("rtsp://user:pass@camera-host:554/Streaming/Channels/101", text: $rtspURL)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to fall back to camsnap config if present.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply & Reload") {
                    onApply()
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
