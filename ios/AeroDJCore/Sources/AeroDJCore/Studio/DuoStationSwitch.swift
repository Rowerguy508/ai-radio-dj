import Foundation

/// The Duo station dial (#463). A swipe only moves the highlight. A station opens
/// only from an explicit tap, or from Tune on the highlighted stop, and only through
/// the caller's existing open action. The station already playing is not opened again.
/// A newer tap supersedes an earlier one, so only the latest open runs.
public enum DuoStationSwitch {
    public struct Stop: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// What the dial did. A snap never carries an open.
    public enum Input: Equatable, Sendable {
        /// Scroll or VoiceOver adjust. Highlight only.
        case snap(String)
        /// A tap on a station, or Tune on the highlighted one.
        case tap(String)
    }

    public struct Flight: Equatable, Sendable {
        public var highlightID: String
        public private(set) var generation = 0
        /// The id of the open that is still allowed to run, if any.
        public private(set) var pendingID: String?

        public init(highlightID: String) {
            self.highlightID = highlightID
        }

        /// Returns a token when this tap should start an open. Nil when the station
        /// is already playing. A later tap makes the earlier token stale.
        public mutating func receive(_ input: Input, playingID: String) -> Int? {
            switch input {
            case .snap(let id):
                highlightID = id
                return nil
            case .tap(let id):
                highlightID = id
                guard id != playingID else { return nil }
                generation += 1
                pendingID = id
                return generation
            }
        }

        /// True only for the newest tap. An older token must not call open.
        public func accepts(_ token: Int) -> Bool {
            token == generation && pendingID != nil
        }
    }

    /// Index a horizontal drag would highlight. Out of range clamps. An empty strip snaps nowhere.
    public static func snappedIndex(offset: Double, count: Int) -> Int? {
        guard count > 0, offset.isFinite else { return nil }
        return min(count - 1, max(0, Int(offset.rounded())))
    }
}
