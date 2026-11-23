import Foundation

/// #434 (owner, Nov 23 2026): which surface shows the orb and which shows the art, per state
/// and pose. Idle and Starting move into the folded player's art frame (a dim ember, a warming
/// orb with a held contrast ring). The DJ talking state keeps the lava-lamp orb. On the open
/// Duo the art hides while the DJ talks, as on iPhone. Landscape centred (L2) puts the one orb
/// in the gap by the trailing rail. Pure and UI-free so Linux can test it. Nothing here reads
/// or changes playback, speech or session state. -Nova

/// What the art card's frame shows.
public enum ArtCardStage: Equatable, Sendable {
    /// Album or station art with its glow (a song is playing or paused).
    case artwork
    /// The DJ is on air: the lava-lamp orb in place of the art (shipping iPhone card).
    case talking
    /// Nothing playing: a static dim ember in the frame.
    case idle
    /// A station is starting: a warming orb and a held contrast ring.
    case starting
    /// The art is hidden and the frame is left clear (the orb sits by the rail instead).
    case cleared
}

/// The layout the player is drawn in.
public enum OnAirOrbPose: Equatable, Sendable {
    /// iPhone and the closed Duo (`FoldedOuterLayout.usesOuterReskin`). Always the same.
    case folded
    /// The open Duo's two halves (portrait).
    case openDuoHalves
    /// The open Duo's L1 book spread (landscape).
    case openDuoSpread
    /// L2: art and title centred across the player, rail trailing.
    case centred
    /// Regular-width two halves that are not the open Duo (iPad). Unchanged.
    case wideHalves
}

public struct OnAirOrbPresentation: Equatable, Sendable {
    /// Nil: no art card at all (the state keeps its own page or column).
    public var card: ArtCardStage?
    /// The 120 pt visualizer in the content column (today's regular-width halves).
    public var showsContentColumnOrb: Bool
    /// The orb in the gap between the centred art and the trailing rail.
    public var showsRailGapOrb: Bool

    /// The rail-gap orb's side as a fraction of the art's.
    public static let railGapOrbFraction = 0.42
    /// Clear space kept on both sides of the rail-gap orb.
    public static let railGapMargin = 16.0
    /// Below this the rail-gap orb is dropped rather than drawn too small.
    public static let railGapMinSide = 44.0

    public init(card: ArtCardStage?, showsContentColumnOrb: Bool, showsRailGapOrb: Bool) {
        self.card = card
        self.showsContentColumnOrb = showsContentColumnOrb
        self.showsRailGapOrb = showsRailGapOrb
    }

    public static func resolve(content: NowPlayingContent, isOnAir: Bool, pose: OnAirOrbPose) -> OnAirOrbPresentation {
        switch content {
        case .track:
            switch pose {
            case .folded, .openDuoHalves, .openDuoSpread:
                return .init(card: isOnAir ? .talking : .artwork, showsContentColumnOrb: false, showsRailGapOrb: false)
            case .centred:
                return .init(card: isOnAir ? .cleared : .artwork, showsContentColumnOrb: false, showsRailGapOrb: isOnAir)
            case .wideHalves:
                // iPad keeps the art (`keepArtVisible`) and the content-column visualizer.
                return .init(card: .artwork, showsContentColumnOrb: DuoPresentation.showsVisualizer(isOnAir: isOnAir),
                             showsRailGapOrb: false)
            }
        case .nothingPlaying:
            return .init(card: pose == .folded ? .idle : nil, showsContentColumnOrb: false, showsRailGapOrb: false)
        case .starting:
            return .init(card: pose == .folded ? .starting : nil, showsContentColumnOrb: false, showsRailGapOrb: false)
        default:
            return .init(card: nil, showsContentColumnOrb: false, showsRailGapOrb: false)
        }
    }

    /// The rail-gap orb, sized from the art and centred in the gap between the centred art's
    /// trailing edge and the rail. `trailingReserve`: width inside `playerWidth` the rail
    /// covers (the system bar). Nil when this state has no rail-gap orb or the gap is too
    /// narrow for a 44 pt orb with its margins.
    public func railGapOrb(playerWidth: Double, artSide: Double, trailingReserve: Double) -> RailGapOrb? {
        guard showsRailGapOrb, playerWidth.isFinite, artSide.isFinite, trailingReserve.isFinite,
              artSide > 0 else { return nil }
        let gap = (playerWidth - artSide) / 2 - max(0, trailingReserve)
        let side = min(artSide * Self.railGapOrbFraction, gap - 2 * Self.railGapMargin)
        guard side >= Self.railGapMinSide else { return nil }
        return RailGapOrb(side: side, offsetFromArtCentre: artSide / 2 + gap / 2)
    }
}

public struct RailGapOrb: Equatable, Sendable {
    public var side: Double
    /// Horizontal offset from the art's centre to the orb's centre (toward the rail).
    public var offsetFromArtCentre: Double
}

extension FoldedArtCardLayers {
    /// Idle ember: ~36% of the card side (still ≥ 44 pt at the smallest art).
    public static let idleOrbFraction = 0.36
    /// Starting orb: ~52% of the card side.
    public static let startingOrbFraction = 0.52
    /// The starting contrast ring is this much larger than the starting orb.
    public static let startingRingScale = 1.1
    /// The ring is a held 240° arc, not a spinner.
    public static let startingRingArcFraction = 240.0 / 360.0
    public static let startingRingLineWidth = 2.0

    public static func layers(stage: ArtCardStage) -> FoldedArtCardLayers {
        switch stage {
        case .artwork: layers(isOnAir: false)
        case .talking: layers(isOnAir: true)
        case .idle, .starting, .cleared: FoldedArtCardLayers(artworkOpacity: 0, glowOpacity: 0, showsOrb: false)
        }
    }

    public static func orbFraction(for stage: ArtCardStage) -> Double {
        switch stage {
        case .talking: orbFraction
        case .idle: idleOrbFraction
        case .starting: startingOrbFraction
        case .artwork, .cleared: 0
        }
    }

    /// The drawn orb side in a card of `cardSide`. Idle and Starting keep at least 44 pt
    /// (accessibility sizes shrink the art), never more than the card. Talking is unchanged.
    public static func orbSide(for stage: ArtCardStage, cardSide: Double) -> Double {
        let side = cardSide * orbFraction(for: stage)
        switch stage {
        case .idle, .starting: return min(cardSide, max(44, side))
        default: return side
        }
    }
}

extension DJOrbPolicy {
    /// The starting ring's drawn fraction. Reduce Motion: a complete static circle.
    public static func startingRingArc(reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : FoldedArtCardLayers.startingRingArcFraction
    }
}

extension FoldedOuterLayout {
    /// #434: the states the folded reskin draws. A track as before, plus Idle and Starting,
    /// which now sit in the folded player's art frame. Pass to `usesOuterReskin(showsTrack:)`.
    public static func reskinShows(_ content: NowPlayingContent) -> Bool {
        switch content {
        case .track, .nothingPlaying, .starting: true
        default: false
        }
    }
}
