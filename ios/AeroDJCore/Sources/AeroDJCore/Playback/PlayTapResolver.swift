import Foundation

/// Why a song-row play tap could not build a queue. Messages for the UI live at the
/// MusicKit boundary (TEMPORARY rule); this type is for tests and call-site branching only.
public enum PlayTapResolveFailure: Error, Equatable, Sendable {
    case startIndexOutOfRange
    case tracksUnavailable
}

/// Pure resolution for a search-result play tap. Used by the app-scoped search cache so
/// `MusicSearch.live` can be rebuilt on every `PlayerView` body without losing hits, and so
/// Linux tests cover each silent-exit case without MusicKit.
public enum PlayTapResolver {
    /// Resolve the MusicKit track IDs to play.
    ///
    /// When `orderedIDs` still matches `allResultIDs` (same search the UI is showing), returns
    /// the ordered slice from `startIndex` — the results captured at search time, not a fresh
    /// per-row lookup. Otherwise the tapped ID must be in `available` (else `.tracksUnavailable`),
    /// and the rest of the slice is filtered through `available`.
    public static func resolveIDs(
        allResultIDs: [String],
        startIndex: Int,
        orderedIDs: [String],
        available: Set<String>
    ) -> Result<[String], PlayTapResolveFailure> {
        guard allResultIDs.indices.contains(startIndex) else {
            return .failure(.startIndexOutOfRange)
        }
        if orderedIDs == allResultIDs {
            return .success(Array(orderedIDs[startIndex...]))
        }
        // The tapped song itself must resolve; never start a different song than the one tapped.
        guard available.contains(allResultIDs[startIndex]) else {
            return .failure(.tracksUnavailable)
        }
        let resolved = allResultIDs[startIndex...].filter { available.contains($0) }
        return .success(Array(resolved))
    }
}
