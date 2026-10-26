import Foundation

/// Why a selected file was not imported. Skips are reported, never fatal.
public enum ObsidianSkipReason: Error, Equatable, Sendable {
    case invalidPath
    case outsideScope          // absolute path or `..` traversal
    case hiddenOrSystem        // `.obsidian/`, `.trash/`, `.git/`, dotfiles
    case unsupportedType       // not .md / .markdown
    case tooLarge
    case binaryContent
    case notUTF8
    case accessDenied          // security-scoped access refused or revoked
    case bookmarkStale         // file moved/renamed; user must re-select
    case notDownloaded         // iCloud placeholder not available offline
    case notFound
    case optedOut              // frontmatter `aerodj: false` / `private: true`
    case empty                 // nothing speakable after sanitizing
    case fileLimitReached
}

/// Scope and content limits for user-selected Obsidian files. Paths are
/// relative to the folder the user picked; nothing outside it is accepted.
public struct ObsidianImportPolicy: Sendable {
    public var maxFileBytes: Int
    public var maxFiles: Int
    public var allowedExtensions: Set<String>

    public init(maxFileBytes: Int = 256 * 1024, maxFiles: Int = 200,
                allowedExtensions: Set<String> = ["md", "markdown"]) {
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.allowedExtensions = allowedExtensions
    }

    /// Returns `nil` if `relativePath` may be read, otherwise the reason it may not.
    public func rejection(forPath relativePath: String) -> ObsidianSkipReason? {
        guard !relativePath.isEmpty, !relativePath.contains("\0"), !relativePath.contains("\\")
        else { return .invalidPath }
        if relativePath.hasPrefix("/") || relativePath.hasPrefix("~") { return .outsideScope }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains(where: { $0 == ".." }) { return .outsideScope }
        if components.contains(where: { $0.isEmpty || $0 == "." }) { return .invalidPath }
        if components.contains(where: { $0.hasPrefix(".") }) { return .hiddenOrSystem }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return .unsupportedType }
        return nil
    }

    /// Decodes file bytes as UTF-8 Markdown, rejecting oversized or binary data.
    public func decode(_ data: Data) -> Result<String, ObsidianSkipReason> {
        guard data.count <= maxFileBytes else { return .failure(.tooLarge) }
        guard !data.contains(0) else { return .failure(.binaryContent) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.notUTF8) }
        return .success(text)
    }
}
