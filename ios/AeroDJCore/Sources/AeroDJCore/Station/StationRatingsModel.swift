import Foundation
import Observation

/// The song being rated, as the player knows it. Never logged.
public struct StationRatedSong: Equatable, Sendable {
    public let songID: String
    public let artistName: String
    /// From the feed's last build (`StationQueueFeed.artistID(forSong:)`); only love's discovery uses it.
    public let artistID: String?
    /// Where the song entered the queue; unknown fails closed (never steers discovery).
    public let origin: TrackOrigin

    public init(songID: String, artistName: String, artistID: String? = nil, origin: TrackOrigin = .unknown) {
        self.songID = songID
        self.artistName = artistName
        self.artistID = artistID
        self.origin = origin
    }
}

/// One edit the listener made, so the toast can undo it.
public struct StationRatingChange: Equatable, Sendable {
    public let scope: StationRatingScope
    public let songID: String
    /// The song's entry before the edit (nil: it was not rated). Undo puts it back.
    public let previous: StationRatingEntry?
    /// What the book holds now. Nil when the tap cleared it (the same level again, "Clear rating")
    /// or when the cap evicted the fresh rating at once: the UI always reads the book, never the tap.
    public let rating: SongRating?
}

/// Ratings in the app (-Nova, PR B): the one `StationRatingBook`, loaded from and saved to a
/// `StationRatingStore` (the app's `FileStationRatingStore`). Main actor; saves run in order.
/// - Before `load()` finishes, and after a load that found a newer file, rating does nothing
///   (`rate` returns nil) so a file this build cannot read is never overwritten.
/// - A corrupt file loads as empty and is replaced at the next save (it could never be read again).
/// - `listen(to:)` clears everything on a purge-all (`NarrationPurgeFeed` `.all`: consent withdrawal,
///   data reset), the same as Settings "Clear all ratings".
/// Ratings never reach the DJ or a voice: only `StationQueueFeed` reads `bias`.
@MainActor
@Observable
public final class StationRatingsModel {
    public enum LoadState: Equatable, Sendable {
        case notLoaded
        case loaded
        /// The saved file is newer than this build, or could not be read: nothing is saved.
        case readOnly
    }

    public private(set) var book = StationRatingBook()
    public private(set) var loadState: LoadState = .notLoaded

    @ObservationIgnored private let store: any StationRatingStore
    @ObservationIgnored private let today: @MainActor () -> Int
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?

    /// The feed's day number (days since the reference date).
    public nonisolated static func dayNumber(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSinceReferenceDate / 86_400)
    }

    public init(store: any StationRatingStore, today: @escaping @MainActor () -> Int = { StationRatingsModel.dayNumber() }) {
        self.store = store
        self.today = today
    }

    /// Once at launch, before the station queue starts (so its first build has the ratings).
    public func load() async {
        guard loadState == .notLoaded else { return }
        do {
            var loaded = try await store.load()
            loaded.prune(today: today())
            book = loaded
            loadState = .loaded
        } catch StationRatingStoreError.corrupt {
            loadState = .loaded
        } catch {
            loadState = .readOnly
        }
    }

    public var canRate: Bool { loadState == .loaded }

    public func rating(for songID: String, in scope: StationRatingScope?) -> SongRating? {
        guard let scope else { return nil }
        return book.rating(for: songID, in: scope)
    }

    /// Sets `level` on `song` (the same level again clears it). Nil: nothing changed (no scope, a
    /// tags-only station, or not loaded). The change's `rating` may still be nil (cleared, evicted).
    @discardableResult
    public func rate(_ level: SongRating, song: StationRatedSong, in scope: StationRatingScope?) -> StationRatingChange? {
        guard canRate, let scope else { return nil }
        let previous = book.ratings(for: scope).entries[song.songID]
        let day = today()
        let after = book.rate(StationRatingEntry(songID: song.songID, artistName: song.artistName, artistID: song.artistID,
                                                 rating: level, ratedDay: day, origin: song.origin),
                              in: scope, today: day)
        scheduleSave()
        return StationRatingChange(scope: scope, songID: song.songID, previous: previous, rating: after)
    }

    /// The menu's "Clear rating".
    @discardableResult
    public func clear(songID: String, in scope: StationRatingScope?) -> StationRatingChange? {
        guard canRate, let scope, let previous = book.ratings(for: scope).entries[songID] else { return nil }
        book.clear(songID: songID, in: scope)
        scheduleSave()
        return StationRatingChange(scope: scope, songID: songID, previous: previous, rating: nil)
    }

    /// The toast's Undo: the song's rating goes back to what it was (usually: not rated). A song
    /// already skipped is not brought back.
    public func undo(_ change: StationRatingChange) {
        guard canRate else { return }
        book.clear(songID: change.songID, in: change.scope)
        if let previous = change.previous { book.rate(previous, in: change.scope, today: today()) }
        scheduleSave()
    }

    /// The per-station "Clear ratings", and deleting a saved station.
    public func clearStation(_ scope: StationRatingScope) {
        guard canRate else { return }
        book.clearStation(scope)
        scheduleSave()
    }

    /// Settings "Clear all ratings" and purge-all: empties the book and deletes the file, after any
    /// save already queued (so nothing written earlier lands after the delete). Allowed read-only
    /// too: the listener asked for everything to go.
    /// False when the file could not be deleted (Sentinel, #387 N1): the book and load state go back
    /// to what they were, so memory still matches the file (which still holds those ratings and
    /// would load them at the next launch), and the caller shows an error instead of "cleared".
    /// A rating made while the delete ran is left as it is: its save, queued after the delete,
    /// writes the book the listener sees.
    @discardableResult
    public func clearAll() async -> Bool {
        let before = book
        let stateBefore = loadState
        book.clearAll()
        loadState = .loaded
        let previous = lastWrite
        let store = store
        let delete = Task { @MainActor () -> Bool in
            await previous?.value
            do {
                try await store.deleteAll()
                return true
            } catch {
                return false
            }
        }
        let marker = Task { @MainActor in _ = await delete.value }
        lastWrite = marker
        let deleted = await delete.value
        if !deleted, lastWrite == marker {
            book = before
            loadState = stateBefore
        }
        return deleted
    }

    /// Clears everything on every purge-all from now on. Call once.
    public func listen(to feed: NarrationPurgeFeed) {
        guard listener == nil else { return }
        let updates = feed.updates()
        listener = Task { @MainActor [weak self] in
            for await purge in updates where purge == .all {
                guard let self else { return }
                // A failed delete puts the book back (it still matches the file); a purge has no one
                // to tell, and the ratings stay in effect as the file has them.
                await self.clearAll()
            }
        }
    }

    /// For `StationQueueFeed(ratings:)`.
    public func bias(recipeID: UUID?, configuration: StationConfiguration) -> StationRatingBias {
        book.bias(recipeID: recipeID, configuration: configuration, today: today())
    }

    /// Waits for queued saves and deletes (tests; the app never waits).
    public func flush() async { await lastWrite?.value }

    private func scheduleSave() {
        let snapshot = book
        let previous = lastWrite
        let store = store
        lastWrite = Task { @MainActor in
            await previous?.value
            try? await store.save(snapshot)
        }
    }
}

extension StationRatingScope {
    /// The scope for the committed station: the recipe last applied when it is still saved and still
    /// has the same seeds (an edited or deleted recipe falls back to the seeds), else the seeds. Nil
    /// for a tags-only station. The app's feed and rating button both use this, so they always agree.
    public static func recipeID(lastApplied: UUID?, recipes: [StationRecipe],
                                committed: StationConfiguration) -> UUID? {
        guard let lastApplied, let key = StationQueueKey(committed),
              let recipe = recipes.first(where: { $0.id == lastApplied }),
              StationQueueKey(recipe.configuration)?.seedsFingerprint == key.seedsFingerprint else { return nil }
        return lastApplied
    }
}

/// Which prepared breaks a rating drops (-Nova, PR B). A break at boundary k plays between song k and
/// song k + 1 and may name both ("that was k", "up next k + 1"), so a queued song j that is now
/// excluded loses the breaks at j - 1 and j. Only boundaries still ahead (k >= the playing index):
/// the break after the playing song is the next one to air.
public enum StationRatingBreakDrop {
    public static func boundaries(forUpcoming indices: [Int], playing: Int) -> [Int] {
        Array(Set(indices.flatMap { [$0 - 1, $0] }.filter { $0 >= max(playing, 0) })).sorted()
    }
}

/// A gap break that a system interruption paused (#379) resumes its script from the interrupted
/// line once the interruption ends. A rating that drops that break's boundary
/// (`StationRatingBreakDrop`) while it is paused must not let the resume re-air it: the script may
/// name the song just rated never. One per interlude player; it only says whether a resume may
/// go ahead. A break that is speaking keeps its line (stopping a speaking break is separate work).
/// Pure, so the order of open, drop, resume and close is tested on Linux.
public struct StationRatingResumeGate: Equatable, Sendable {
    /// The boundary of the gap break handed to the player, until that break ends.
    public private(set) var openBreak: Int?
    /// A rating dropped `openBreak`'s boundary while it was open.
    public private(set) var withdrawn = false

    public init() {}

    /// A gap break for boundary `k` was handed to the player. A new break starts unwithdrawn.
    public mutating func breakOpened(afterTrack k: Int) {
        openBreak = k
        withdrawn = false
    }

    /// The open break ended (finished, failed, cancelled or revoked).
    public mutating func breakClosed() {
        openBreak = nil
        withdrawn = false
    }

    /// A rating dropped the break at boundary `k`. True when that is the open break, which then
    /// never resumes after an interruption. Any other boundary changes nothing here.
    @discardableResult
    public mutating func boundaryDropped(afterTrack k: Int) -> Bool {
        guard openBreak == k else { return false }
        withdrawn = true
        return true
    }

    /// Whether the open break may resume its script (or play the apology first) after an
    /// interruption ends. False: the break ends instead, and music follows as after any break.
    public var mayResume: Bool { !withdrawn }
}

/// The lines a withdrawn break (`StationRatingResumeGate`) did not air, by kind, for the P0 trace
/// (Echo, #387 N1). Like `BreakResumeDrop`: counts and kinds only, never text, titles or IDs, and
/// nothing about the rating that withdrew it.
public struct StationRatingWithdrawnLines: Equatable, Sendable {
    /// The interrupted line (the first one not aired).
    public let line: Int
    public let timeChecks: Int
    public let other: Int

    public init(line: Int, timeChecks: Int, other: Int) {
        self.line = line
        self.timeChecks = timeChecks
        self.other = other
    }

    public var count: Int { timeChecks + other }

    /// Every line from `line` on (none when `line` is out of range).
    public static func remaining(_ lines: [BreakResumeLine], from line: Int) -> StationRatingWithdrawnLines {
        let rest = lines.indices.contains(line) ? Array(lines[line...]) : []
        let checks = rest.filter { $0.dropKind == .timeCheck }.count
        return StationRatingWithdrawnLines(line: line, timeChecks: checks, other: rest.count - checks)
    }
}

/// Copy and symbols for the rating button (ratings scope §3). The app draws them; tests pin them.
public enum SongRatingPresentation {
    /// Menu order: the positive levels first, never last (it skips).
    public static let menuOrder: [SongRating] = [.love, .like, .tired, .never]
    public static let unratedSymbol = "star"
    public static let clearTitle = "Clear rating"
    public static let clearSymbol = "xmark.circle"
    /// The short label next to the button until the first rating on this device.
    public static let firstTimeLabel = "Rate"
    /// UserDefaults flag (`ratingsLabelSeen`): set by the first rating.
    public static let labelSeenKey = "AeroDJRatingsLabelSeen"
    public static let clearStationTitle = "Clear ratings for this station"
    public static let clearAllTitle = "Clear all ratings"
    public static let clearAllFooter = "Ratings stay on this device and are not backed up. Clearing them can't be undone."
    /// Settings, when the ratings file could not be deleted (the ratings are still there).
    public static let clearAllFailed = "Couldn't clear ratings. Try again."
    public static let undoTitle = "Undo"

    public static func symbol(_ rating: SongRating?) -> String {
        switch rating {
        case nil: unratedSymbol
        case .tired: "moon.zzz"
        case .never: "nosign"
        case .like: "plus.circle"
        case .love: "heart.fill"
        }
    }

    public static func title(_ rating: SongRating) -> String {
        switch rating {
        case .tired: "Tired of it"
        case .never: "Never play on this station"
        case .like: "Like it"
        case .love: "More like this"
        }
    }

    public static func accessibilityLabel(_ rating: SongRating?) -> String {
        "Rate song, current: " + (rating.map(title) ?? "not rated")
    }

    /// The Undo toast (scope §3): only a never shows one; the other levels change the button only.
    /// `skipped`: the playing song was skipped.
    public static func toast(_ change: StationRatingChange, skipped: Bool) -> String? {
        guard change.rating == .never else { return nil }
        return skipped ? "Skipped. Won't play on this station again." : "Won't play on this station again."
    }
}
