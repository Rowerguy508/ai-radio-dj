import Foundation

// #465 item 3: the tent / tabletop pose (owner mockup onairly2-mockups/03-tent.png).
//
// There is no "tent" or "tabletop" pose type in Apple's SDK. The only signal is the hinge:
// SwiftUI `onHingeChange(isEnabled:_:)` hands over a `DeviceHingeContext` whose optional
// `hinge` has a `status` (.closed / .partiallyOpen / .fullyOpen) and an `angle`. That API is
// iOS 27.1 and needs the Xcode 27 SDK; the required CI build is Xcode 26.6 with the iOS 26.5
// SDK, so the app reads the hinge only under `#if compiler(>=6.4.2)` and
// `if #available(iOS 27.1, *)`, and hands this file a plain `DuoHingeSample`.
//
// Everything here is pure and UI-free, so the decision is driven by Linux tests and by the
// StudioCapture `duoTent` scenario. No playback, DJ session or device model is read.

/// The pose the listen player draws for.
public enum DuoPose: String, Equatable, Sendable {
    /// Every layout that existed before #465 item 3: phone, folded, unfolded flat, iPad.
    case flat
    /// Propped open with the fold horizontal: the hands-free radio face.
    case tent
}

/// One hinge reading, copied out of `DeviceHinge` so AeroDJCore never imports the SDK type.
public struct DuoHingeSample: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case closed
        case partiallyOpen
        case fullyOpen
        /// A status this build does not know (UIKit has `.unknown`; new SDK cases land here).
        case unknown
    }

    public let status: Status
    /// Opening angle in degrees as the SDK reports it (0 shut, 180 flat). Non-finite is ignored.
    public let angleDegrees: Double

    public init(status: Status, angleDegrees: Double) {
        self.status = status
        self.angleDegrees = angleDegrees
    }
}

public enum DuoPoseDecision {
    /// Angles that turn the tent on. Assumed, not measured on a Duo: a tent or a tabletop
    /// stand sits well inside 45...135 degrees.
    public static let enterDegrees: ClosedRange<Double> = 45...135
    /// Once in the tent, it stays until the angle leaves this wider band, so a hand resting
    /// on the device near a threshold cannot flip the layout back and forth.
    public static let holdDegrees: ClosedRange<Double> = 35...150
    /// The face needs a landscape container (fold horizontal) at least this big. Below it,
    /// or in portrait (fold vertical: the unfolded Duo split), nothing changes.
    public static let minContainerWidth: Double = FoldedColumnLayout.wideMinWidth
    public static let minContainerHeight: Double = 400

    /// `previous` is the pose on screen now (hysteresis). A nil hinge is every device without
    /// one, and any SDK before iOS 27.1: always `.flat`.
    public static func resolve(hinge: DuoHingeSample?, containerWidth: Double, containerHeight: Double,
                               previous: DuoPose = .flat) -> DuoPose {
        guard let hinge, hinge.status == .partiallyOpen, hinge.angleDegrees.isFinite else { return .flat }
        guard containerWidth.isFinite, containerHeight.isFinite,
              containerWidth > containerHeight,
              containerWidth >= minContainerWidth,
              containerHeight >= minContainerHeight else { return .flat }
        let band = previous == .tent ? holdDegrees : enterDegrees
        return band.contains(hinge.angleDegrees) ? .tent : .flat
    }
}

// MARK: - Layout

/// Geometry of the tent pose, in container points. The owner frame is 820 × 640 pt (the
/// measured 640 × 820 unfolded Duo, rotated) with the fold drawn horizontally at y = 320.
public struct TentPoseLayout: Equatable, Sendable {
    /// Where the revealed controls go. The owner mockup keeps everything on the face (the
    /// back half faces away and takes no touch). `lowerHalf` is the issue text's tabletop
    /// variant, kept so it is one constant away if the owner picks it on a real Duo.
    public enum ControlsPlacement: String, Equatable, Sendable {
        case onFace
        case lowerHalf
    }

    /// The face: top half above the fold band.
    public let faceHeight: Double
    /// Empty band centred on the fold. Nothing is drawn or placed in it.
    public let foldBand: Double
    /// The half that faces away. Dark, no content, no touch.
    public let lowerHeight: Double
    public let leadingInset: Double
    public let trailingInset: Double
    /// Orb or artwork side.
    public let heroSide: Double
    public let clockPointSize: Double
    public let stationColumnWidth: Double
    /// False at accessibility text sizes or narrow faces: one scrolling column instead.
    public let usesColumns: Bool
    public let controlsPlacement: ControlsPlacement

    public static let ownerWidth: Double = 820
    public static let foldBand: Double = FoldedColumnLayout.duoFoldGutter
    public static let maxClockPointSize: Double = 150
    public static let minClockPointSize: Double = 64
    public static let maxHeroSide: Double = 140
    public static let stationColumnWidth: Double = 200
    /// Three columns need at least this width (hero 180, clock 300, station 200, gaps).
    public static let columnsMinWidth: Double = 720

    public static func make(containerWidth: Double, containerHeight: Double,
                            accessibilityText: Bool,
                            controlsPlacement: ControlsPlacement = .onFace) -> TentPoseLayout {
        let width = containerWidth.isFinite ? max(0, containerWidth) : 0
        let height = containerHeight.isFinite ? max(0, containerHeight) : 0
        let half = max(0, (height - foldBand) / 2)
        let byHeight = half * 0.49
        let byWidth = maxClockPointSize * width / ownerWidth
        let clock = max(minClockPointSize, min(maxClockPointSize, byHeight, byWidth))
        return TentPoseLayout(faceHeight: half, foldBand: foldBand, lowerHeight: half,
                              leadingInset: 50, trailingInset: 20,
                              heroSide: max(0, min(maxHeroSide, half * 0.46)),
                              clockPointSize: clock,
                              stationColumnWidth: stationColumnWidth,
                              usesColumns: !accessibilityText && width >= columnsMinWidth,
                              controlsPlacement: controlsPlacement)
    }
}

// MARK: - Controls

/// The face shows no buttons until it is touched (owner mockup). A tap fades the glass
/// controls up; they hide again after `autoHideSeconds` with no touch.
public enum TentControlsPolicy {
    public static let revealSeconds: Double = 0.25
    public static let autoHideSeconds: Double = 5
    /// Big transport: Play/Pause and Skip. Both at least 60 pt (Fry: 44 pt floor everywhere).
    public static let playSide: Double = 96
    public static let skipSide: Double = 72
    public static let bigTransportMinSide: Double = 60
    /// Station dial stops, the break chip and the small chrome buttons.
    public static let targetMinSide: Double = 52
    public static let hitTargetFloor: Double = 44

    public enum Transition: String, Equatable, Sendable {
        /// Opacity plus a 12 pt rise.
        case fadeUp
        /// Reduce Motion: opacity only.
        case crossfade
    }

    public static func transition(reduceMotion: Bool) -> Transition {
        reduceMotion ? .crossfade : .fadeUp
    }

    /// VoiceOver and Switch Control cannot find a control that is not there, so with either
    /// running the controls are always shown and never auto-hide.
    public static func showsControls(lastTouch: Date?, now: Date,
                                     assistiveTechnology: Bool, holdOpen: Bool = false) -> Bool {
        if assistiveTechnology || holdOpen { return true }
        guard let lastTouch else { return false }
        let elapsed = now.timeIntervalSince(lastTouch)
        return elapsed >= 0 && elapsed < autoHideSeconds
    }

    public static func autoHides(assistiveTechnology: Bool, holdOpen: Bool = false) -> Bool {
        !(assistiveTechnology || holdOpen)
    }
}

// MARK: - Face

/// What the face shows, read only from presentation values the UI already has.
public enum TentFace {
    /// The big round thing in the hero column.
    public enum Hero: String, Equatable, Sendable {
        /// Confirmed speaking, motion allowed: the live lava orb.
        case liveOrb
        /// Confirmed speaking under Reduce Motion: a still orb, no animation at all.
        case stillOrb
        /// Anything else: the song's artwork (station art when there is none).
        case artwork
        /// Nothing playing: station art.
        case stationArt
    }

    public static func hero(state: DJStudioState, reduceMotion: Bool, hasTrack: Bool) -> Hero {
        if onAirLabel(state) != nil { return reduceMotion ? .stillOrb : .liveOrb }
        return hasTrack ? .artwork : .stationArt
    }

    /// The tally. Its only source is `DJStudioState.onAirLabel` (Fry), which is non-nil only
    /// in the player-confirmed `.speaking` state.
    public static func onAirLabel(_ state: DJStudioState) -> String? {
        state.onAirLabel
    }

    /// The break chip: the ready-break headline, only while a break is ready. Read-only:
    /// the headline is `DJStatusPresentation.headline`, which comes from the DJ presentation
    /// store. Nothing here reaches `DJBreakSession`.
    public static func breakChip(state: DJStudioState, headline: String?) -> String? {
        guard case .ready = state, let headline, !headline.isEmpty else { return nil }
        return headline
    }

    /// Caption over the next song: "Up after the break" only while the DJ is on air.
    public static func nextCaption(state: DJStudioState) -> String {
        onAirLabel(state) != nil ? "Up after the break" : "Up next"
    }

    /// One VoiceOver summary for the whole face, so a listener hears it as one radio readout.
    public static func accessibilitySummary(time: String, station: String, state: DJStudioState,
                                            next: (title: String, artist: String)?) -> String {
        var parts = ["\(AppName.display) radio face", time, "Station \(station)"]
        if let label = onAirLabel(state) { parts.append(label) }
        if let next {
            parts.append("\(nextCaption(state: state)): \(next.title) by \(next.artist)")
        }
        return parts.joined(separator: ". ")
    }
}
