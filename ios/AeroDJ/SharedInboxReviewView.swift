import AeroDJCore
import SwiftUI

/// Review screen for items the user shared into AeroDJ via the Share Extension.
/// Include / exclude, label the source, redact, or delete. Nothing is narrated
/// unless included. Not yet linked from navigation: `StationListView` belongs to
/// the app-shell PR (#27/#16), so the entry point is a follow-up.
struct SharedInboxReviewView: View {
    let review: SharedInboxReview

    @State private var entries: [SharedReviewEntry] = []
    @State private var errorMessage: String?
    @State private var editingID: UUID?
    @State private var draft = ""

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing shared yet", systemImage: "tray",
                    description: Text("In Mail, Messages or Safari, tap Share and choose AeroDJ.")
                )
            }
            ForEach(entries) { entry in
                row(entry)
            }
        }
        .navigationTitle("Shared with AeroDJ")
        .task { perform { [review] in _ = try await review.refresh() } }
        .refreshable { perform { [review] in _ = try await review.refresh() } }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
            NavigationStack {
                TextEditor(text: $draft)
                    .padding()
                    .navigationTitle("Edit before narration")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingID = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                if let id = editingID {
                                    let text = draft
                                    perform { [review] in try await review.redact(id, to: text) }
                                }
                                editingID = nil
                            }
                        }
                    }
            }
        }
    }

    private func row(_ entry: SharedReviewEntry) -> some View {
        let id = entry.id
        return VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayText).lineLimit(4)
            Picker("Shared from", selection: Binding(
                get: { entry.label },
                set: { label in perform { [review] in try await review.setLabel(label, for: id) } }
            )) {
                Text("Email").tag(SharedSourceLabel.email)
                Text("Message").tag(SharedSourceLabel.message)
                Text("Other").tag(SharedSourceLabel.other)
            }
            .pickerStyle(.segmented)
            Toggle("Include in my briefing", isOn: Binding(
                get: { entry.decision == .approved },
                set: { on in perform { [review] in try await review.setDecision(on ? .approved : .excluded, for: id) } }
            ))
        }
        .accessibilityElement(children: .contain)
        .swipeActions {
            Button("Delete", role: .destructive) { perform { [review] in try await review.delete(id) } }
            Button("Edit") {
                draft = entry.displayText
                editingID = id
            }
        }
    }

    private func perform(_ action: @escaping @Sendable () async throws -> Void) {
        let review = review
        Task {
            do {
                try await action()
            } catch {
                errorMessage = Self.message(for: error)
            }
            entries = await review.entries
        }
    }
}

extension SharedInboxReviewView {
    /// Plain-language alert text; never internal type names.
    static func message(for error: Error) -> String {
        switch error as? SharedReviewError {
        case .emptyRedaction: return "The edited text can't be empty."
        case .unknownItem: return "That item is no longer in your inbox."
        case nil: return "Something went wrong. Please try again."
        }
    }
}

extension SharedInboxReview {
    /// Review backed by the App Group inbox the Share Extension writes to.
    static func appGroupInbox() -> SharedInboxReview? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.aerodj"
        ) else { return nil }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        let state = container.appendingPathComponent("Review/state.json", isDirectory: false)
        return SharedInboxReview(reader: SharedInboxReader(directory: inbox), store: SharedReviewStore(file: state))
    }
}

#Preview {
    NavigationStack {
        SharedInboxReviewView(review: SharedInboxReview(
            reader: SharedInboxReader(directory: FileManager.default.temporaryDirectory)
        ))
    }
}
