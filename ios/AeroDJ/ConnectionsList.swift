import AeroDJCore
import SwiftUI

/// Connections workspace (studio-presentation-contract.md, Connections). One card per
/// `ConnectionSourceRow`: fixed privacy scope, truthful state, and only the actions the
/// model offers for that state. Every button is routed by `ConnectionUICapabilities`, so
/// it either does something real or is replaced by text that says why it can't.
/// "Connected" appears only when `mayShowConnected`.
///
/// Originally written by Claudio (#60); taken over and revised by Fry.
struct ConnectionsList: View {
    let model: ConnectionsModel
    var capabilities: ConnectionUICapabilities = .current

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var calendarPicker = false
    @State private var reviewing: ReviewTarget?
    @State private var returningFromSettings = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                if let error = model.lastError {
                    Label(Self.message(for: error), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ForEach(model.sources) { row in SourceCard(row: row, perform: { handle($0, on: row) },
                                                           route: { capabilities.route($0, onSource: row.integration) }) }
                Text("Turning a source off or deleting an item also removes any DJ speech prepared from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.bottom, 16)
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Access can only change in Settings; re-read it when the listener comes back.
            if phase == .active, returningFromSettings {
                returningFromSettings = false
                Task { await model.refresh() }
            }
        }
        .sheet(isPresented: $calendarPicker) {
            CalendarPickerSheet(model: model)
        }
        .sheet(item: $reviewing) { target in
            ItemReviewSheet(model: model, integration: target.integration)
        }
    }

    private func handle(_ action: ConnectionAction, on row: ConnectionSourceRow) {
        switch capabilities.route(action, onSource: row.integration) {
        case .model: Task { _ = await model.perform(action, onSource: row.integration) }
        case .systemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                returningFromSettings = true
                openURL(url)
            }
        case .calendarPicker: calendarPicker = true
        case .itemReview: reviewing = ReviewTarget(integration: row.integration)
        case .unavailable: break   // rendered as text, never as a button
        }
    }

    static func message(for error: ConnectionActionError) -> String {
        switch error {
        case .notAllowed: "That isn't available for this item right now."
        case .unknownItem: "That item is no longer here."
        case .failed: "Something went wrong. Anything the DJ prepared from it was already removed."
        }
    }
}

/// The source whose items are being reviewed (sheet identity).
private struct ReviewTarget: Identifiable {
    let integration: StationIntegration
    var id: String { integration.rawValue }
}

private struct SourceCard: View {
    let row: ConnectionSourceRow
    let perform: (ConnectionAction) -> Void
    let route: (ConnectionAction) -> ConnectionActionRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(row.title).font(.headline)
                Spacer(minLength: 8)
                if let badge = row.badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(row.mayShowConnected ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15)))
                        .foregroundStyle(row.mayShowConnected ? Color.green : Color.secondary)
                        .accessibilityIdentifier("connections.badge.\(row.integration.rawValue)")
                }
            }
            .accessibilityElement(children: .combine)

            Text(row.description)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(row.scope)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let actions = row.actions
            if !actions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons(actions) }
                    VStack(alignment: .leading, spacing: 8) { buttons(actions) }
                }
            }
            ForEach(unavailableReasons(actions), id: \.self) { reason in
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("connections.source.\(row.integration.rawValue)")
    }

    @ViewBuilder
    private func buttons(_ actions: [ConnectionAction]) -> some View {
        ForEach(actions.filter { if case .unavailable = route($0) { false } else { true } }, id: \.self) { action in
            Button(role: action.purgesNarration ? .destructive : nil) {
                perform(action)
            } label: {
                Text(title(action)).font(.subheadline.weight(.medium)).frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("connections.\(row.integration.rawValue).\(action.rawValue)")
        }
    }

    private func unavailableReasons(_ actions: [ConnectionAction]) -> [String] {
        Array(Set(actions.compactMap { if case .unavailable(let r) = route($0) { r } else { nil } })).sorted()
    }

    private func title(_ action: ConnectionAction) -> String {
        if action == .review, row.reviewableItemCount > 0 { return "Review (\(row.reviewableItemCount))" }
        if action == .reselect, row.integration == .shareInbox { return "Review" }
        return action.title
    }

    private var icon: String {
        switch row.integration {
        case .calendar: "calendar"
        case .obsidian: "doc.text"
        case .shareInbox: "square.and.arrow.down"
        }
    }
}

/// Picks which calendars AeroDJ may read. Only offered with Full Access.
private struct CalendarPickerSheet: View {
    let model: ConnectionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.calendar.calendars, id: \.id) { cal in
                        Toggle(cal.title, isOn: Binding(get: { selection.contains(cal.id) },
                                                        set: { on in if on { selection.insert(cal.id) } else { selection.remove(cal.id) } }))
                    }
                } footer: {
                    Text(failed ? "Couldn't save your choice. Try again." : "AeroDJ reads today's events only from the calendars you pick.")
                }
            }
            .overlay {
                if model.calendar.calendars.isEmpty {
                    ContentUnavailableView("No calendars", systemImage: "calendar",
                                           description: Text("There are no calendars on this device to choose from."))
                }
            }
            .navigationTitle("Choose calendars")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if case .success = await model.selectCalendars(selection) { dismiss() } else { failed = true }
                        }
                    }
                }
            }
            .onAppear { selection = model.calendar.selectedCalendarIDs }
        }
    }
}

/// Item-level review: approve, read anyway, review, stop using, delete.
private struct ItemReviewSheet: View {
    let model: ConnectionsModel
    let integration: StationIntegration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.items(for: integration)) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Text(item.description).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            ForEach(item.actions.filter { $0 != .review }, id: \.self) { action in
                                Button(action.title, role: action.purgesNarration ? .destructive : nil) {
                                    Task { _ = await model.perform(action, on: item.id) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .overlay {
                if model.items(for: integration).isEmpty {
                    ContentUnavailableView("Nothing to review", systemImage: "tray",
                                           description: Text("Items you share to AeroDJ appear here."))
                }
            }
            .navigationTitle(StationSetting.integration(integration).title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

#Preview("Connections") {
    ConnectionsPreviewLoader()
}

private struct ConnectionsPreviewLoader: View {
    @State private var studio: StudioPresentationModel?
    var body: some View {
        Group {
            if let studio { ConnectionsList(model: studio.connections).padding() } else { ProgressView() }
        }
        .task { studio = await StudioPresentationModel.preview() }
    }
}
