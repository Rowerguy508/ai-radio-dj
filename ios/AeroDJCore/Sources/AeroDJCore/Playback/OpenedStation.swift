import Foundation

/// The station the listener opened from the list.
///
/// A song tap plays on this station. It must not open another row (Morning Calm
/// must not become Late Night). Only `open` changes the selection.
public struct OpenedStation: Equatable, Sendable {
    public private(set) var station: StationRef?

    public init(station: StationRef? = nil) {
        self.station = station
    }

    public mutating func open(_ station: StationRef) {
        self.station = station
    }

    /// The station a song tap must pass to playback.
    public func stationForSongTap() -> StationRef? {
        station
    }
}
