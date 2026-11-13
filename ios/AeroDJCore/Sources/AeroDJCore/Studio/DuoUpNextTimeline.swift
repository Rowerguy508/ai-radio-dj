import Foundation

/// The Duo content-column timeline (#460 follow-up). It lists the song that is playing,
/// a DJ-break line only when one is already ready, and the songs already in
/// `PlaybackSnapshot.upNext`. It does not plan breaks or change the queue.
public enum DuoUpNextTimeline {
    public struct Line: Equatable, Sendable {
        public enum Role: String, Equatable, Sendable {
            case nowPlaying
            case breakChip
            case queued
        }

        public let role: Role
        public let title: String
        public let detail: String

        public init(role: Role, title: String, detail: String) {
            self.role = role
            self.title = title
            self.detail = detail
        }
    }

    public struct Song: Equatable, Sendable {
        public let title: String
        public let artist: String

        public init(title: String, artist: String) {
            self.title = title
            self.artist = artist
        }
    }

    /// `readyBreak` is the published ready-state headline, or nil when nothing is ready.
    public static func lines(now: Song, readyBreak: String?, queued: [Song]) -> [Line] {
        var lines = [Line(role: .nowPlaying, title: now.title, detail: now.artist)]
        if let readyBreak, !readyBreak.isEmpty {
            lines.append(Line(role: .breakChip, title: readyBreak, detail: ""))
        }
        lines.append(contentsOf: queued.map { Line(role: .queued, title: $0.title, detail: $0.artist) })
        return lines
    }
}
