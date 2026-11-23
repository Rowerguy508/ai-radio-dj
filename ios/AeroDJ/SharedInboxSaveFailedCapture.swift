#if DEBUG
import AeroDJCore
import SwiftUI

/// #426 (-Sentinel): capture for `StudioCaptureScenario.sharedInboxSaveFailed`. One fixed shared
/// item in a throwaway temp inbox, and a review store whose backup exclusion always reads back
/// unset, so any change hits the fail-closed path and shows its alert. Nothing real is read.
struct SharedInboxSaveFailedCapture: View {
    private struct UnverifiedExclusion: BackupExclusionMarking {
        func markExcluded(_ directory: URL) throws {}
        func isExcluded(_ directory: URL) throws -> Bool? { false }
    }

    @State private var review: SharedInboxReview?

    var body: some View {
        Group {
            if let review {
                NavigationStack { SharedInboxReviewView(review: review) }
            } else {
                Color.clear
            }
        }
        .task { if review == nil { review = Self.makeReview() } }
    }

    private static func makeReview() -> SharedInboxReview? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeroDJCaptureSaveFailed-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        guard let item = SharedInboxItem(kind: .text, content: "Lunch moved to noon on Friday.", now: Date()),
              let data = try? JSONEncoder().encode(item) else { return nil }
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try data.write(to: inbox.appendingPathComponent("\(item.id.uuidString).json"))
        } catch {
            return nil
        }
        let store = SharedReviewStore(file: root.appendingPathComponent("Review/state.json"),
                                      backupExclusion: UnverifiedExclusion(), backupExclusionLog: { _ in })
        return SharedInboxReview(reader: SharedInboxReader(directory: inbox), store: store)
    }
}
#endif
