import Foundation
import Observation

// Station start screen state (-Atlas, #454). A station row tap shows Now Playing for that station
// at once: "Starting <name>…" until its first song is on screen, then the song. If the start fails
// (`notReadyInTime`, `buildFailed`, a recipe that could not be applied), the same screen says
// "Couldn't start <name>" with Try again; a station with nothing to apply (an id no station has)
// says so honestly. Never the search field. Decisions live here so they are tested on Linux.
// Holds only the station's id and display name: no seeds, songs or personal content.

/// What the Now Playing area shows for a station that is starting, or failed to start.
public struct StationStartState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The tap is starting the station; nothing of it is on screen yet.
        case starting
        /// The start ended with nothing playing. Try again re-runs the same tap.
        case failed
        /// The station has nothing to play yet (an id that is no station). No retry.
        case unavailable
    }

    public let stationID: String
    public let stationName: String
    public let phase: Phase
    /// The song on screen when the tap happened (a switch), so the old song is not mistaken for
    /// the new station's first song. Nil when nothing was playing.
    public let songAtTap: String?

    public init(stationID: String, stationName: String, phase: Phase, songAtTap: String?) {
        self.stationID = stationID
        self.stationName = stationName
        self.phase = phase
        self.songAtTap = songAtTap
    }
}

/// One per app session (`StudioPresentationModel.stationStart`). Only the latest tap's outcome counts.
@MainActor @Observable
public final class StationStartStatus {
    public private(set) var state: StationStartState?
    @ObservationIgnored private var tap = 0
    /// Re-runs the latest tap (Try again). Set by the app with each tap; nil hides the button.
    @ObservationIgnored public private(set) var retryAction: (@MainActor () -> Void)?

    public init() {}

    /// A station row was tapped. Shows "Starting <name>…" for it and returns this tap's token.
    @discardableResult
    public func begin(stationID: String, stationName: String, songAtTap: String?,
                      retry: (@MainActor () -> Void)? = nil) -> Int {
        tap += 1
        retryAction = retry
        state = StationStartState(stationID: stationID, stationName: stationName, phase: .starting,
                                  songAtTap: songAtTap)
        return tap
    }

    /// The tap's outcome. A started, already-playing, restored or replaced tap clears the state;
    /// a failure keeps the station's screen with Try again; a station with no recipe says so.
    public func finish(tap token: Int, outcome: CreatedStationOpenOutcome) {
        guard token == tap, let current = state else { return }
        switch Self.phase(after: outcome) {
        case nil:
            state = nil
        case let phase?:
            state = StationStartState(stationID: current.stationID, stationName: current.stationName,
                                      phase: phase, songAtTap: current.songAtTap)
        }
    }

    /// Try again: runs the latest tap's retry (the same start path as the tap). No-op otherwise.
    public func retry() {
        guard state?.phase == .failed, let retryAction else { return }
        retryAction()
    }

    /// The phase an outcome leaves on screen, nil when the start screen should go away.
    public nonisolated static func phase(after outcome: CreatedStationOpenOutcome) -> StationStartState.Phase? {
        switch outcome {
        case .restoredOnly, .alreadyPlaying, .resumed, .started:
            return nil
        case .notApplied:
            return .failed
        case .notStarted(let reason):
            switch reason {
            case .noStation, .notReadyInTime, .buildFailed: return .failed
            case .notAvailableYet: return .unavailable
            // The listener chose something else (a newer tap owns the screen, or a song tap / Play).
            case .playbackBegan, .superseded: return nil
            }
        }
    }

    /// The state to show on the opened station's screen, or nil (show the player as usual).
    /// `.starting` covers the old song during a switch until a different song is on screen.
    /// A failure is shown only while nothing plays: a failed switch keeps the old song playing.
    public nonisolated static func shown(_ state: StationStartState?, openedStationID: String?,
                                         nowPlaying: TrackInfo?) -> StationStartState? {
        guard let state, let openedStationID, state.stationID == openedStationID else { return nil }
        switch state.phase {
        case .starting:
            guard let nowPlaying else { return state }
            return nowPlaying.id == state.songAtTap ? state : nil
        case .failed, .unavailable:
            return nowPlaying == nil ? state : nil
        }
    }
}

/// #454 (-Atlas): how a station row tap names the station it starts. Built-ins come from Fry's
/// `BuiltInStations` (#442); created and library stations from their saved recipe. Nothing invented.
public enum StationStartFacts {
    /// The recipe a built-in row applies (its fixed configuration, keyed by the row id), or nil
    /// for an id that is not a built-in station.
    public static func builtInRecipe(for stationID: UUID) -> StationRecipe? {
        BuiltInStations.station(id: stationID).map {
            StationRecipe(id: $0.id, name: $0.name, configuration: $0.configuration)
        }
    }

    /// Intro facts for a built-in row: its name, row copy and seeds.
    public static func builtIn(_ stationID: UUID) -> StationIntroFacts? {
        BuiltInStations.station(id: stationID).map {
            StationIntroFacts(id: $0.id.uuidString, name: $0.name, description: $0.summary,
                              seeds: $0.configuration.seeds)
        }
    }

    /// Intro facts for a created (or library) station: its saved name and seeds, no description.
    public static func created(_ recipe: StationRecipe) -> StationIntroFacts {
        StationIntroFacts(id: recipe.id.uuidString, name: recipe.name, seeds: recipe.configuration.seeds)
    }
}
