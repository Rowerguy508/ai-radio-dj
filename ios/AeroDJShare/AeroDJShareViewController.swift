import AeroDJCore
import UIKit
import UniformTypeIdentifiers

/// Share Extension: imports plain text or a URL the user explicitly shares.
/// Never implies whole-inbox access. Writes one bounded, expiring
/// `SharedInboxItem` to the App Group inbox; the host app enforces retention.
@objc(AeroDJShareViewController)
final class AeroDJShareViewController: UIViewController {
    static let appGroupID = "group.com.aerodj"

    enum ShareError: Error {
        case noSupportedAttachment
        case emptyContent
        case appGroupUnavailable
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await handleShare() }
    }

    private func handleShare() async {
        do {
            let (kind, content) = try await loadFirstSupportedAttachment()
            guard let item = SharedInboxItem(kind: kind, content: content, now: Date()) else {
                throw ShareError.emptyContent
            }
            try write(item)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func loadFirstSupportedAttachment() async throws -> (SharedInboxItem.Kind, String) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try await loadURL(from: provider) {
                return (.url, url.absoluteString)
            }
            if provider.canLoadObject(ofClass: String.self),
               let text = try await loadText(from: provider) {
                return (.text, text)
            }
        }
        throw ShareError.noSupportedAttachment
    }

    // The callbacks below run on an arbitrary queue; only the Sendable value
    // crosses back, and the provider itself stays on the main actor.

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: text) }
            }
        }
    }

    private func write(_ item: SharedInboxItem) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            throw ShareError.appGroupUnavailable
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("\(item.id.uuidString).json")
        try JSONEncoder().encode(item).write(
            to: file,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }
}
