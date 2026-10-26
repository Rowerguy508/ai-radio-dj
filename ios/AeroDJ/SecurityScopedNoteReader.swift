import AeroDJCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Reads one Markdown file the user picked, through its security-scoped bookmark. Access is
/// opened only for the read and closed right after. Nothing outside the picked file is
/// touched: no directory listing, no vault access. Content goes to the #38 parser via
/// `ObsidianContextSource`; it is never stored.
struct SecurityScopedNoteReader: SecurityScopedFileReading {
    /// Larger files are refused before reading (the import policy caps text at 256 KB).
    static let maxBytes = 1_048_576

    func read(bookmark: Data) async throws -> (data: Data, renewedBookmark: Data?) {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw MarkdownReadError.notFound
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // The picked file itself, not something a symlink now points to.
        guard url.resolvingSymlinksInPath().pathExtension.lowercased() == "md" else { throw MarkdownReadError.accessDenied }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey, .isRegularFileKey])
        if let status = values?.ubiquitousItemDownloadingStatus, status == .notDownloaded {
            throw MarkdownReadError.notDownloaded
        }
        if values?.isRegularFile == false { throw MarkdownReadError.accessDenied }
        if let size = values?.fileSize, size > Self.maxBytes { throw MarkdownReadError.accessDenied }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw MarkdownReadError.accessDenied
        } catch {
            throw scoped ? MarkdownReadError.notFound : MarkdownReadError.accessDenied
        }
        guard stale else { return (data, nil) }
        // Still readable but moved or renamed: renew the bookmark while access is open.
        guard let renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            throw MarkdownReadError.bookmarkStale
        }
        return (data, renewed)
    }

    /// Bookmarks for the files the user just picked (`.md` only; anything else is ignored).
    static func pickedNotes(from urls: [URL]) -> [PickedNote] {
        urls.compactMap { url in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            else { return nil }
            return PickedNote(fileName: url.lastPathComponent, bookmark: bookmark)
        }
    }

    /// `.md` files. Falls back to plain text when the system has no Markdown type.
    static var contentTypes: [UTType] {
        [UTType(filenameExtension: "md", conformingTo: .text), UTType("net.daringfireball.markdown")]
            .compactMap { $0 } + [.plainText]
    }
}

/// The live note store, when this build has one. Set at the root; read by `ConnectionsList`.
private struct PickedNotesKey: EnvironmentKey { static let defaultValue: LiveConnectionSources? = nil }

extension EnvironmentValues {
    var pickedNotes: LiveConnectionSources? {
        get { self[PickedNotesKey.self] }
        set { self[PickedNotesKey.self] = newValue }
    }
}
