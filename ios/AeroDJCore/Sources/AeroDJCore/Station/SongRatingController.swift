import Foundation
import Observation

/// The rating button's logic (-Nova, PR B), tested on Linux; the app gives it live hooks
/// (`SongRatingController.live` in SongRatingControl.swift) and draws it in `TrackBlock`.
/// - The button always shows the book's rating after the tap, never the tapped level: a tap on the
///   current level clears it, and a fresh rating the cap evicts at once reads as not rated.
/// - Never on the song that is playing skips it (`skipPlaying`: `MusicKitService.skip()`, a user
///   skip, so its break is dropped); the toast offers Undo, which puts the old rating back but
///   does not bring the song back. Tired never skips.
/// - Every change calls `ratingsChanged` first (the station queue rebuilds and drops the prepared
///   breaks that name a queued, now-excluded song), so no break names a song the listener just
///   ruled out.
/// Never logs a song, an artist, a rating or a station.
@MainActor
@Observable
public final class SongRatingController {
    public struct Toast: Equatable, Sendable {
        public let id: UUID
        public let message: String
        public let change: StationRatingChange
    }

    public struct Hooks {
        /// The committed station's scope, or nil (tags-only: no button).
        public var scope: @MainActor () -> StationRatingScope?
        public var playingSongID: @MainActor () -> String?
        public var origin: @MainActor (String) -> TrackOrigin
        public var artistID: @MainActor (String) -> String?
        public var skipPlaying: @MainActor () async -> Void
        public var ratingsChanged: @MainActor () async -> Void

        public init(scope: @escaping @MainActor () -> StationRatingScope?,
                    playingSongID: @escaping @MainActor () -> String? = { nil },
                    origin: @escaping @MainActor (String) -> TrackOrigin = { _ in .unknown },
                    artistID: @escaping @MainActor (String) -> String? = { _ in nil },
                    skipPlaying: @escaping @MainActor () async -> Void = {},
                    ratingsChanged: @escaping @MainActor () async -> Void = {}) {
            self.scope = scope
            self.playingSongID = playingSongID
            self.origin = origin
            self.artistID = artistID
            self.skipPlaying = skipPlaying
            self.ratingsChanged = ratingsChanged
        }
    }

    public static let toastDuration: Duration = .seconds(6)

    public let ratings: StationRatingsModel
    public private(set) var toast: Toast?
    /// The first-time "Rate" label is hidden once this device has rated a song.
    public private(set) var labelSeen: Bool
    @ObservationIgnored private let hooks: Hooks
    @ObservationIgnored private let defaults: UserDefaults

    public init(ratings: StationRatingsModel, hooks: Hooks, defaults: UserDefaults = .standard) {
        self.ratings = ratings
        self.hooks = hooks
        self.defaults = defaults
        labelSeen = defaults.bool(forKey: SongRatingPresentation.labelSeenKey)
    }

    /// The button is drawn only when a rating can be kept: ratings loaded, a seeded station.
    public var isAvailable: Bool { ratings.canRate && hooks.scope() != nil }

    public func rating(for songID: String) -> SongRating? { ratings.rating(for: songID, in: hooks.scope()) }

    /// A menu item. Nil: nothing changed (see `StationRatingsModel.rate`).
    @discardableResult
    public func rate(_ level: SongRating, songID: String, artistName: String) async -> StationRatingChange? {
        let song = StationRatedSong(songID: songID, artistName: artistName, artistID: hooks.artistID(songID),
                                    origin: hooks.origin(songID))
        guard let change = ratings.rate(level, song: song, in: hooks.scope()) else { return nil }
        markLabelSeen()
        let skips = change.rating == .never && hooks.playingSongID() == songID
        await hooks.ratingsChanged()
        if skips { await hooks.skipPlaying() }
        if let message = SongRatingPresentation.toast(change, skipped: skips) {
            toast = Toast(id: UUID(), message: message, change: change)
        }
        return change
    }

    /// The menu's "Clear rating".
    public func clearRating(songID: String) async {
        guard ratings.clear(songID: songID, in: hooks.scope()) != nil else { return }
        if toast?.change.songID == songID { toast = nil }
        await hooks.ratingsChanged()
    }

    /// The toast's Undo.
    public func undo() async {
        guard let shown = toast else { return }
        toast = nil
        ratings.undo(shown.change)
        await hooks.ratingsChanged()
    }

    /// The toast's timer: only the toast it was started for.
    public func dismissToast(id: UUID) {
        if toast?.id == id { toast = nil }
    }

    /// "Clear ratings for this station".
    public func clearStation() async {
        guard let scope = hooks.scope() else { return }
        ratings.clearStation(scope)
        toast = nil
        await hooks.ratingsChanged()
    }

    /// Settings "Clear all ratings": deletes the file.
    public func clearAll() async {
        await ratings.clearAll()
        toast = nil
        await hooks.ratingsChanged()
    }

    /// A saved station was deleted: its ratings go with it (scope §5).
    public func stationDeleted(recipeID: UUID) {
        ratings.clearStation(.recipe(recipeID))
    }

    private func markLabelSeen() {
        guard !labelSeen else { return }
        labelSeen = true
        defaults.set(true, forKey: SongRatingPresentation.labelSeenKey)
    }
}
