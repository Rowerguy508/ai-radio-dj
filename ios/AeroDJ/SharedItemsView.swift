import SwiftUI
import AeroDJCore

/// Review UI for user-shared items. Delete removes immediately (prevents
/// narration). No background inbox scanning — only what the user shared.
struct SharedItemsView: View {
    @StateObject private var store = SharedItemStore()

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No shared items",
                        systemImage: "square.and.arrow.up",
                        description: Text("Share text or links to AeroDJ from Mail, Messages, or Safari.")
                    )
                } else {
                    List {
                        ForEach(store.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.text)
                                    .font(.body)
                                    .lineLimit(3)
                                HStack {
                                    Text(item.isURL ? "Link" : "Text")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(item.createdAt, format: .dateTime)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shared Items")
            .onAppear { store.refresh() }
        }
    }
}

#Preview {
    SharedItemsView()
}
