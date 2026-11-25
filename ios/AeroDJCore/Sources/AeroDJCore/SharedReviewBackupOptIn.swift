import Foundation

/// #592 (-Atlas): the user's explicit opt-in to let shared-inbox review choices (`Review/state.json`)
/// go into iCloud and computer backups. Core logic only; the Settings toggle is a separate UI change.
///
/// Off by default, and every doubt reads as off, so #426's fail-closed save stays the default:
/// - The choice is one small file next to the store, `<file>.backup-opt-in`, holding exactly `on`.
///   Missing, unreadable or any other content is off. It holds no content and no ids.
/// - Turning it on counts only once the file reads back as `on`. Otherwise the opt-in is removed
///   again and `SharedReviewError.backupOptInUnverified` is thrown.
/// - While it is on, `save` skips the backup-exclusion requirement, and turning it on clears the
///   folder's excluded flag (best effort: if that fails the folder stays excluded, which is the
///   private direction, and one content-free line is logged).
/// - Turning it off ends it for this process at once, removes the file (or overwrites it with
///   `off`), then re-marks the folder excluded with the read-back. If the mark fails, the saved
///   choices are removed through `removeSavedChoices()` (#593's fail-closed path, unchanged) and
///   `SharedReviewError.reviewChoicesResetUnverified` is thrown.
/// - Opting in never ends a #593 revocation by itself. Only a save that completes does
///   (`save` clears the revocation after its write), and with the opt-in unverified a save still
///   needs the verified exclusion mark.
struct SharedReviewBackupOptInOps: Sendable {
    var write: @Sendable (Data, URL) throws -> Void
    var read: @Sendable (URL) throws -> Data
    var remove: @Sendable (URL) throws -> Void
    /// Clears `isExcludedFromBackup` on the folder. A no-op off Apple platforms.
    var markIncluded: @Sendable (URL) throws -> Void

    static let live = SharedReviewBackupOptInOps(
        write: { data, url in try ProtectedFile.write(data, to: url) },
        read: { try Data(contentsOf: $0) },
        remove: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        },
        markIncluded: { directory in
            #if canImport(Darwin)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = false
            try url.setResourceValues(values)
            #endif
        })
}

/// #592: files whose backup opt-in was turned off in this process. Wins over the opt-in file, so
/// an opt-out that could not remove the file still holds until relaunch. Standardized paths only.
final class SharedReviewBackupOptOuts: @unchecked Sendable {
    static let shared = SharedReviewBackupOptOuts()
    private let lock = NSLock()
    private var paths: Set<String> = []
    func optOut(_ file: URL) { lock.withLock { _ = paths.insert(file.standardizedFileURL.path) } }
    func clear(_ file: URL) { lock.withLock { _ = paths.remove(file.standardizedFileURL.path) } }
    func contains(_ file: URL) -> Bool { lock.withLock { paths.contains(file.standardizedFileURL.path) } }
}

extension SharedReviewStore {
    static let backupOptInOn = Data("on".utf8)
    static let backupOptInOff = Data("off".utf8)

    /// The opt-in file: `<file>.backup-opt-in`.
    public var backupOptInFile: URL { file.appendingPathExtension("backup-opt-in") }

    /// The only line logged when the folder's excluded flag could not be cleared. No path, no error text.
    public static let backupInclusionFailureMessage = "AeroDJ.review backup inclusion failed, folder stays excluded"
    /// The only line logged when an opt-out could not remove or overwrite the opt-in file.
    public static let backupOptOutNotPersistedMessage = "AeroDJ.review backup opt-out not saved, off until relaunch"

    /// True only when the user turned the opt-in on and the file still reads back exactly `on`,
    /// and it was not turned off in this process.
    public var isBackupOptedIn: Bool {
        guard !SharedReviewBackupOptOuts.shared.contains(file) else { return false }
        return (try? optInOps.read(backupOptInFile)) == Self.backupOptInOn
    }

    /// Turns the backup opt-in on or off. See `SharedReviewBackupOptInOps` for the rules.
    public func setBackupOptIn(_ on: Bool) throws {
        if on { try optIn() } else { try optOut() }
    }

    private func optIn() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let verified: Bool
        do {
            try optInOps.write(Self.backupOptInOn, backupOptInFile)
            verified = (try? optInOps.read(backupOptInFile)) == Self.backupOptInOn
        } catch { verified = false }
        guard verified else {
            // Leave nothing that a later read could take as on.
            try? optInOps.remove(backupOptInFile)
            throw SharedReviewError.backupOptInUnverified
        }
        SharedReviewBackupOptOuts.shared.clear(file)
        do { try optInOps.markIncluded(file.deletingLastPathComponent()) } catch {
            backupExclusionLog(Self.backupInclusionFailureMessage)
        }
    }

    private func optOut() throws {
        // Off for this process first, whatever the disk does next.
        SharedReviewBackupOptOuts.shared.optOut(file)
        if (try? optInOps.remove(backupOptInFile)) == nil,
           (try? optInOps.write(Self.backupOptInOff, backupOptInFile)) == nil {
            backupExclusionLog(Self.backupOptOutNotPersistedMessage)
        }
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        guard markFolderExcludedFromBackup() else {
            // #592: the folder may still be backed up, so the saved choices go (#593's path).
            removeSavedChoices()
            throw SharedReviewError.reviewChoicesResetUnverified
        }
    }
}
