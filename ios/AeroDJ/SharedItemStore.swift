import Foundation
import AeroDJCore

/// App Group-backed store for user-shared items. Bounded retention enforced
/// on every read. Deleting an item removes it immediately so it can't be
/// narrated. No background inbox scanning.
@MainActor
final class SharedItemStore: ObservableObject {
    @Published private(set) var items: [SharedItem] = []

    private let validator = SharedItemValidator()
    private let groupID = "group.com.aerodj"

    private var inboxURL: URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        return container.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Load + prune (bounded retention). Called on app open and on review view appear.
    func refresh() {
        guard let inbox = inboxURL else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let loaded = files.compactMap { url -> SharedItem? in
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? UUID()
            return SharedItem(id: id, text: text, source: "userShared", createdAt: date)
        }
        items = validator.prune(loaded)
    }

    /// Delete an item immediately — prevents narration.
    func delete(_ item: SharedItem) {
        guard let inbox = inboxURL else { return }
        let file = inbox.appendingPathComponent("\(item.id.uuidString).txt")
        try? FileManager.default.removeItem(at: file)
        items.removeAll { $0.id == item.id }
    }
}
