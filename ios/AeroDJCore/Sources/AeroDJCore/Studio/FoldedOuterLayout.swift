import Foundation

/// #465 01-folded: metrics and DJ-status rules for the Duo outer-screen compact reskin.
///
/// Pure and UI-free so Linux can test them. Ships ungated (owner, 9:53 PM, logged on
/// #300 and #491): the iPhone and the folded Duo draw this reskin whenever the folded
/// player is at phone width with a track showing. `FoldedStyle` and
/// `FoldedPlayer.compactBody` stay for every other phone-width state (nothing playing,
/// starting, failed). The mockup's outer size is 390 × 844 pt.
///
/// The tinted ring around play was deferred from item 9. These tokens do not depend
/// on `GlassTreatment` or the item 9 branch, which is not on integration yet.
public enum FoldedOuterLayout {
    /// Mockup content gutter (`left: 24`).
    public static let contentInset: Double = 24
    /// Art inset in the mockup (`left: 30`).
    public static let artInset: Double = 30
    /// Art corner radius in the 01-folded mockup.
    public static let artRadius: Double = 28
    public static let titlePointSize: Double = 34
    public static let artistPointSize: Double = 15
    public static let transportHeight: Double = 80
    public static let transportRadius: Double = 40
    /// Play/Pause disc in the mockup (item 9's shared row stays 68 pt).
    public static let playSide: Double = 64
    /// Outset ring around play, deferred from item 9: a 6 pt teal halo.
    public static let playRingWidth: Double = 6
    public static let playRingOpacity: Double = 0.25
    /// sRGB 47, 212, 190 — the mockup's Morning Calm tint. Not yet hooked to the opened station.
    public static let playRingRed: Double = 47 / 255
    public static let playRingGreen: Double = 212 / 255
    public static let playRingBlue: Double = 190 / 255
    public static let skipSide: Double = 44
    public static let upNextHeight: Double = 44
    public static let upNextRadius: Double = 22
    public static let statusPillHeight: Double = 28

    /// Outer diameter of play plus its ring (64 + 6 + 6). Fits in the 80 pt capsule.
    public static var playOuterSide: Double { playSide + playRingWidth * 2 }

    /// On Air comes only from `DJStudioState.onAirLabel`. Ready and failed never light as
    /// On Air. A failed break stays a quiet skip (mic down, no break error).
    public enum Status: Equatable, Sendable {
        /// Confirmed speaking. The string is exactly `onAirLabel`.
        case onAir(String)
        /// Idle, preparing, ready, or a failed break. Never labelled On Air.
        case micDown
    }

    public static func status(onAirLabel: String?) -> Status {
        if let onAirLabel, !onAirLabel.isEmpty {
            return .onAir(onAirLabel)
        }
        return .micDown
    }

    /// Convenience: reads the label from the state, never from a second flag.
    public static func status(of state: DJStudioState) -> Status {
        status(onAirLabel: state.onAirLabel)
    }
}
