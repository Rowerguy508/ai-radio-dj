import Foundation

/// #592 (-Atlas): the user's explicit opt-in to let shared-inbox review choices (`Review/state.json`)
/// go into iCloud and computer backups. Core logic only; the Settings toggle is a separate UI change.
///
/// Off by default, and every doubt reads as off, so #426's fail-closed save stays the default:
/// - The choice is one small file next to the store, `<file>.backup-opt-in`, holding exactly `on`.
///   Missing, unreadable or any other content is off. It holds no content and no ids.
/// - Turning it on counts only once the file reads back as `on`. Otherwise it is off for this
///   process, the file is removed (or overwritten with `off`), and
///   `SharedReviewError.backupOptInUnverified` is thrown.
/// - While it is on, `save` skips the backup-exclusion requirement, and turning it on clears the
///   folder's excluded flag (best effort: if that fails the folder stays excluded, which is the
///   private direction, and one content-free line is logged). If the choices are revoked (#593),
///   the removal is retried first, and if revoked files remain the folder stays excluded until
///   the first save that completes.
/// - Turning it off (a no-op when already off) ends it for this process at once, removes the file
///   (or overwrites it with `off`), then re-marks the folder excluded with the read-back. If the
///   mark fails, the saved choices are removed through `removeSavedChoices()` (#593's fail-closed
///   path, unchanged) and `SharedReviewError.reviewChoicesResetUnverified` is thrown. If the file
///   could be neither removed nor overwritten, `SharedReviewError.backupOptOutNotPersisted` is thrown.
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
            // Off for this process, and leave nothing that a later read could take as on: remove
            // the file, or overwrite it with `off` (Echo's #651 review: read-back and remove both fail).
            SharedReviewBackupOptOuts.shared.optOut(file)
            if (try? optInOps.remove(backupOptInFile)) == nil,
               (try? optInOps.write(Self.backupOptInOff, backupOptInFile)) == nil {
                // #651 nit 1 (Sentinel, Echo): an `on` may still be on disk, so say so.
                backupExclusionLog(Self.backupOptOutNotPersistedMessage)
                throw SharedReviewError.backupOptOutNotPersisted
            }
            throw SharedReviewError.backupOptInUnverified
        }
        SharedReviewBackupOptOuts.shared.clear(file)
        // Sentinel's N2 on #651: revoked choices (a `state.json` #593 could not remove, or a set-aside
        // `.unreadable` copy) must never become backup-eligible. Retry #593's removal first; if
        // anything is still there, the folder stays excluded until the first save that completes
        // (`includeFolderAfterVerifiedSave`).
        if isRevoked {
            removeSavedChoices()
            guard !FileManager.default.fileExists(atPath: file.path) else { return }
        }
        includeFolder()
    }

    /// Clears the folder's excluded flag. Best effort: on failure it stays excluded (private).
    /// #651 N4 (Sentinel): never while a set-aside `.unreadable` copy is in the folder, revoked or
    /// not, so a corrupt copy of old choices is never backed up.
    private func includeFolder() {
        guard unreadableCopies().isEmpty else { return }
        do { try optInOps.markIncluded(file.deletingLastPathComponent()) } catch {
            backupExclusionLog(Self.backupInclusionFailureMessage)
        }
    }

    /// #651 N5: true only when the opt-in file is missing or reads back exactly `off`.
    private var optInFileIsOff: Bool {
        guard FileManager.default.fileExists(atPath: backupOptInFile.path) else { return true }
        return (try? optInOps.read(backupOptInFile)) == Self.backupOptInOff
    }

    /// #651 N6 (Sentinel): `save` just set a copy aside while opted in, and the folder may already be
    /// included. Re-mark it excluded with the read-back, so the copy is never backed up. False if
    /// the mark could not be verified (the save then fails closed, as without the opt-in).
    func reExcludeFolderForSetAsideCopy() -> Bool {
        guard isBackupOptedIn, !unreadableCopies().isEmpty else { return true }
        return markFolderExcludedFromBackup()
    }

    /// Called by `save` after its write has completed and ended any revocation: with the opt-in
    /// on, the folder may now be backed up.
    func includeFolderAfterVerifiedSave() {
        guard isBackupOptedIn, !isRevoked else { return }
        includeFolder()
    }

    private func optOut() throws {
        // Sentinel's nit (a) on #651: already off is a no-op, but only when it is off on disk too.
        // B3: after a failed opt-out the in-process off hides an `on` still on disk, so a retry
        // must still remove it, or a relaunch would read on and back up the folder.
        // N5 (Sentinel): the retry is skipped only when the file is missing or reads exactly `off`;
        // a failed read (or `on`, or anything else) goes ahead with the opt-out.
        guard isBackupOptedIn || !optInFileIsOff else { return }
        // Off for this process first, whatever the disk does next.
        SharedReviewBackupOptOuts.shared.optOut(file)
        var persisted = true
        if (try? optInOps.remove(backupOptInFile)) == nil,
           (try? optInOps.write(Self.backupOptInOff, backupOptInFile)) == nil {
            backupExclusionLog(Self.backupOptOutNotPersistedMessage)
            persisted = false
        }
        if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), !markFolderExcludedFromBackup() {
            // #592: the folder may still be backed up, so the saved choices go (#593's path).
            removeSavedChoices()
            throw SharedReviewError.reviewChoicesResetUnverified
        }
        // Sentinel's nit (b) on #651: the opt-out holds for this process, but a relaunch may read the
        // old `on`, so the caller is told.
        if !persisted { throw SharedReviewError.backupOptOutNotPersisted }
    }
}
