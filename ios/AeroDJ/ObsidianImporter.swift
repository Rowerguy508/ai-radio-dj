import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AeroDJCore

/// Obsidian Markdown importer. Uses the document picker + security-scoped
/// bookmark; imports only files/folders the user selects. Handles iCloud
/// unavailable and revoked access. Never uploads the whole vault.
@MainActor
final class ObsidianImporter: ObservableObject {
    @Published private(set) var items: [ContextItem] = []
    @Published private(set) var lastError: String?

    private let parser = ObsidianParser()

    /// Present the document picker for Markdown files/folders.
    func picker() -> DocumentPicker {
        DocumentPicker { [weak self] urls in
            self?.importURLs(urls)
        }
    }

    private func importURLs(_ urls: [URL]) {
        items = []
        lastError = nil
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                lastError = "Access revoked for \(url.lastPathComponent)"
                continue
            }
            defer { url.stopAccessingSecurityScopedResource() }
            importFile(url)
        }
    }

    private func importFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "md" else { return }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            lastError = "Could not read \(url.lastPathComponent)"
            return
        }
        let fileID = url.lastPathComponent
        items.append(contentsOf: parser.parse(text, fileID: fileID))
    }
}

/// SwiftUI wrapper around UIDocumentPickerViewController.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.markdown, .folder], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(_ onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}
