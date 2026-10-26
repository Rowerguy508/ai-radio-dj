import AeroDJCore
import SwiftUI

/// Connections workspace (ui-contract.md §2.4, §9). Binds to Fry's `ConnectionsModel`
/// (`StudioPresentationModel.connections`): one row per `ConnectionSourceRow` with
/// truthful description, scope and the exact per-state actions the contract offers
/// (allow access, choose again, open Settings, stop using). "Connected" appears only
/// when `ConnectionSourceRow.mayShowConnected`. Nothing here invents connected state,
/// and nothing claims to manage what it can't toggle off.
struct ConnectionsList: View {
    let model: ConnectionsModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.sources) { row in
                    rowView(row)
                    if row.id != model.sources.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .onAppear { Task { await model.refresh() } }
    }

    @ViewBuilder
    private func rowView(_ row: ConnectionSourceRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon(for: row.integration))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    statusLine(row)
                }

                Spacer()

                if row.mayShowConnected {
                    connectedBadge
                }
            }

            Text(row.scope)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !row.actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(row.actions, id: \.self) { action in
                        Button {
                            Task { await model.perform(action, onSource: row.integration) }
                        } label: {
                            Text(action.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func statusLine(_ row: ConnectionSourceRow) -> some View {
        if !row.mayShowConnected {
            Text(row.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectedBadge: some View {
        Text("Connected")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.green.opacity(0.12)))
            .lineLimit(1)
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
    @State private var studio: StudioPresentationModel?

    var body: some View {
        Group {
            if let studio {
                ConnectionsList(model: studio.connections)
            } else {
                ProgressView()
            }
        }
        .task { studio = await StudioPresentationModel.preview() }
    }
}
