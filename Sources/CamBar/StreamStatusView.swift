import SwiftUI

struct StreamStatusView: View {
    let sourceURLMasked: String?
    let lagSeconds: Double?
    let lastUpdated: Date?
    var showPlaceholders: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text("Source: \(sourceURLMasked ?? "—")")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let lagSeconds {
                Text("Lag \(lagSeconds, specifier: "%.1f")s")
                    .foregroundColor(.secondary)
            } else if showPlaceholders {
                Text("Lag --")
                    .foregroundColor(.secondary)
            }
            if let lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                    .foregroundColor(.secondary)
            } else if showPlaceholders {
                Text("No stream yet")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }
}
