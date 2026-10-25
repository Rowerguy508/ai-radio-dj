import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AeroDJCore

/// Share Extension: imports plain text, URLs, and email/message excerpts the
/// user explicitly shares. Never implies whole-inbox access. Writes to the
/// App Group inbox with bounded retention. Validates length/format.
@objc(AeroDJShareViewController)
class AeroDJShareViewController: UIViewController {
    private let validator = SharedItemValidator()

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first else {
            finish()
            return
        }

        let textType = UTType.text.identifier
        let urlType = UTType.url.identifier

        if provider.hasItemConformingToTypeIdentifier(textType) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] item, _ in
                guard let text = item as? String else { self?.finish(); return }
                self?.store(text: text, source: "userShared")
            }
        } else if provider.hasItemConformingToTypeIdentifier(urlType) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] item, _ in
                guard let url = item as? URL else { self?.finish(); return }
                self?.store(text: url.absoluteString, source: "userShared")
            }
        } else {
            finish()
        }
    }

    private func store(text: String, source: String) {
        // Validate length/format; drop invalid silently (no error UI in share sheet).
        guard let item = try? validator.validate(text, source: source) else {
            finish()
            return
        }
        let groupID = "group.com.aerodj"
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            finish()
            return
        }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("\(item.id.uuidString).txt")
        try? item.text.data(using: .utf8)?.write(to: file)
        finish()
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
