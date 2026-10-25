import Foundation

/// Edits to the songs after the one playing. The playing song is never changed by
/// an edit: it is not in the list, so no edit can cut it off or restart it.
public enum UpNextEdit: Equatable, Sendable {
    case remove(id: String)
    /// Move the song at `from` to `to`, both indices into the current up-next list.
    case move(from: Int, to: Int)
    /// Add a song to the end of up next. Ignored if it is already queued or playing.
    case append(TrackInfo)
}

public enum UpNextEditError: Error, Equatable, Sendable {
    case outOfRange
    case alreadyQueued
    case isPlayingNow
}

/// Applies one edit to the current up-next list. Pure and deterministic; the engine
/// calls this and the result is the new list the UI shows.
public enum UpNextEditor {
    public static func apply(
        _ edit: UpNextEdit,
        to upNext: [TrackInfo],
        nowPlaying: TrackInfo?
    ) -> Result<[TrackInfo], UpNextEditError> {
        switch edit {
        case let .remove(id):
            guard let i = upNext.firstIndex(where: { $0.id == id }) else { return .failure(.outOfRange) }
            var list = upNext
            list.remove(at: i)
            return .success(list)

        case let .move(from, to):
            guard upNext.indices.contains(from), (0..<upNext.count).contains(to) else {
                return .failure(.outOfRange)
            }
            var list = upNext
            let moved = list.remove(at: from)
            list.insert(moved, at: to)
            return .success(list)

        case let .append(track):
            if track.id == nowPlaying?.id { return .failure(.isPlayingNow) }
            if upNext.contains(where: { $0.id == track.id }) { return .failure(.alreadyQueued) }
            return .success(upNext + [track])
        }
    }
}
