import AeroDJCore
import SwiftUI

/// Connections workspace (ui-contract.md §2.4, §9). One row per integration with
/// its truthful `integrationStatus(_:)`. "Connected" appears only when
/// `mayShowConnected`. Requesting never grants access: it routes to the consent
/// flow. Nothing here invents a connected state.
struct ConnectionsList: View {
    let model: StationConfigurationModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(StationIntegration.allCases, id: \.self) { integration in
                    row(for: integration)
                    if integration != StationIntegration.allCases.last {
                        Divider()
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func row(for integration: StationIntegration) -> some View {
        let status = model.integrationStatus(integration)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon(for: integration))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(name(for: integration))
                    .font(.subheadline)
                    .lineLimit(1)
                Text(copy(for: status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            statusBadge(for: status)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            // Requesting routes to consent; it never grants here.
            Task { await model.setIntegration(integration, requested: true) }
        }
    }

    @ViewBuilder
    private func statusBadge(for status: StationIntegrationStatus) -> some View {
        switch status {
        case .on:
            // Only .on may show as connected (mayShowConnected).
            Text("Connected")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.green.opacity(0.12)))
                .lineLimit(1)
        case .off:
            Text("Off")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .checking:
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .consentReviewRequired:
            Text("Consent needed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .blocked:
            Text("Blocked")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func copy(for status: StationIntegrationStatus) -> String {
        switch status {
        case .off:
            "Not requested. Tap to connect — you'll review consent first."
        case .checking:
            "Checking permission…"
        case .on:
            "In use. Items are filtered before narration. Tap to manage."
        case .consentReviewRequired:
            "Needs your review before anything is read."
        case .blocked(let consent):
            switch consent {
            case .denied: "Calendar access is off. Open Settings to allow it."
            case .revoked: "Revoked. Tap to request again."
            case .notRequested: "Needs your review before anything is read."
            case .granted: "In use."
            }
        }
    }

    private func name(for integration: StationIntegration) -> String {
        switch integration {
        case .calendar: "Calendar"
        case .shareInbox: "Shared Items"
        case .obsidian: "Notes"
        }
    }

    private func icon(for integration: StationIntegration) -> String {
        switch integration {
        case .calendar: "calendar"
        case .shareInbox: "square.and.arrow.up"
        case .obsidian: "note.text"
        }
    }
}

#Preview("Connections") {
    ConnectionsListPreviewLoader()
}

struct ConnectionsListPreviewLoader: View {
    @State private var model: StationConfigurationModel?

    var body: some View {
        Group {
            if let model {
                ConnectionsList(model: model)
            } else {
                ProgressView()
            }
        }
        .task { model = await StationConfigurationModel.preview() }
    }
}
