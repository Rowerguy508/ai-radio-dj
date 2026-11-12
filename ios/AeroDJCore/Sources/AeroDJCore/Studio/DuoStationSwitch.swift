import Foundation

/// A horizontal snap between stations on the Duo (#460 follow-up). Choosing a stop
/// calls the same open action a station row uses. The station already open is not
/// opened again. This type does not start playback.
public enum DuoStationSwitch {
    public struct Stop: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Index a horizontal drag lands on. `offset` is in stop-widths from the first stop.
    /// Out of range clamps. An empty strip snaps nowhere.
    public static func snappedIndex(offset: Double, count: Int) -> Int? {
        guard count > 0, offset.isFinite else { return nil }
        return min(count - 1, max(0, Int(offset.rounded())))
    }

    /// Calls `open` with the stop's id when it is not the station already open.
    public static func choose(_ stop: Stop, currentID: String, open: (String) -> Void) {
        guard stop.id != currentID else { return }
        open(stop.id)
    }
}
