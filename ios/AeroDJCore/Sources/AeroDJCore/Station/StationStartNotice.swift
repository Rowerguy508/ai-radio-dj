import Foundation
import Observation

// "Couldn't start that station" (-Nova, Orion's ask after #214). A created-station row tap with
// nothing queued starts the station on the idle-Play path (`CreatedStationStarter`). When that tap
// ends with nothing going to play, the app shows a short toast. Decisions live here so they are
// tested on Linux; the app only draws `message`. Restore never toasts, a boundary switch never
// toasts, and a tap the listener replaced (a newer tap, or Play / a song tap meanwhile) never toasts.
// Apple Music not authorized at that moment says so instead ("Connect Apple Music to play this station").

extension CreatedStationOpenOutcome {
    /// True when the listener's own tap will not play anything and nothing else replaced it.
    public var warrantsStartFailureNotice: Bool {
        switch self {
        case .restoredOnly, .switchesAtBoundary, .started:
            false
        case .notApplied:
            true
        case .notStarted(let reason):
            switch reason {
            case .noStation, .notReadyInTime, .buildFailed: true
            case .playbackBegan, .superseded: false
            }
        }
    }
}

/// One per station list. Only the latest row tap may show the toast; any new tap clears it.
@MainActor @Observable
public final class StationStartNotice {
    /// Fixed copy, never an error's own text.
    public nonisolated static let couldNotStart = "Couldn't start that station"
    /// The same failure while Apple Music isn't authorized (worded like #214's genre step).
    public nonisolated static let connectAppleMusic = "Connect Apple Music to play this station"
    /// How long the toast stays before it dismisses itself.
    public nonisolated static let displayDuration: Duration = .seconds(3)

    /// The toast text, or nil when nothing is shown.
    public private(set) var message: String?
    /// Bumped each time a toast is shown, so the view restarts its auto-dismiss timer and a stale
    /// timer cannot dismiss a newer toast.
    public private(set) var showID = 0
    private var tapID = 0

    public init() {}

    /// A station row was tapped (built-in or created). Clears any toast and returns this tap's token.
    @discardableResult
    public func beginTap() -> Int {
        tapID += 1
        message = nil
        return tapID
    }

    /// The tap's outcome. Shows the toast only for the latest tap and only when it warrants one.
    /// - Parameter musicAuthorized: the app's non-prompting Apple Music status read (never a
    ///   request). Read only when a toast is shown; false picks "Connect Apple Music…".
    public func finish(tap: Int, outcome: CreatedStationOpenOutcome,
                       musicAuthorized: @autoclosure () -> Bool) {
        guard tap == tapID, outcome.warrantsStartFailureNotice else { return }
        message = musicAuthorized() ? Self.couldNotStart : Self.connectAppleMusic
        showID += 1
    }

    /// Hides the toast. With `showID`, only if that toast is still the one showing (auto-dismiss).
    public func dismiss(showID id: Int? = nil) {
        if let id, id != showID { return }
        message = nil
    }
}
