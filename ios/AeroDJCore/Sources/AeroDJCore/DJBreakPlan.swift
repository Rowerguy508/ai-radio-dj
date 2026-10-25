import Foundation

/// Which spoken DJ line plays at which song boundary.
///
/// Keys are the index of the song that just finished, so `[0: "..."]` means
/// "after song 0, before song 1". Every boundary must resolve, with a line
/// or with no line: the caller always moves playback forward either way.
public struct DJBreakPlan: Sendable, Equatable {
    public let linesAfterTrack: [Int: String]

    public init(linesAfterTrack: [Int: String]) {
        self.linesAfterTrack = linesAfterTrack
    }

    public func line(afterTrack index: Int) -> String? {
        linesAfterTrack[index].flatMap { $0.isEmpty ? nil : $0 }
    }
}
