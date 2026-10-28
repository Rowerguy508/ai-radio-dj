import Foundation

/// A session notification reduced to Sendable values. AVFoundation types stay in the app target.
public enum AudioRouteChangeReason: Equatable, Sendable {
    /// `AVAudioSession.RouteChangeReason.oldDeviceUnavailable` (headphones unplugged).
    case oldDeviceUnavailable
    case other
}

public enum AudioSessionNotice: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(AudioRouteChangeReason)

    /// `began` is the interruption type. `shouldResume` is ignored unless the interruption ended.
    public static func interruption(began: Bool, shouldResume: Bool) -> AudioSessionNotice {
        began ? .interruptionBegan : .interruptionEnded(shouldResume: shouldResume)
    }

    public static func routeChange(deviceRemoved: Bool) -> AudioSessionNotice {
        .routeChanged(deviceRemoved ? .oldDeviceUnavailable : .other)
    }
}

/// What the player should do after one session notice or an explicit user pause.
public enum AudioSessionDirective: Equatable, Sendable {
    /// Pause the player and stop a speaking break.
    case suspendPlayback
    /// Play only when `mayAutoResume` is still true after the notice.
    case resumeIfPermitted
    case none
}

/// Maps session notices onto `PlaybackIntent`. One value is applied at a time, in arrival order.
public struct AudioSessionPolicy: Equatable, Sendable {
    private var intent = PlaybackIntent()
    /// A `.interruptionBegan` has not been followed by `.interruptionEnded` yet.
    public private(set) var interruptionOngoing = false

    public init() {}

    public var mayAutoResume: Bool { intent.mayAutoResume }
    public var pausedBySystem: Bool { intent.pausedBySystem }
    public var userWantsPlayback: Bool { intent.userWantsPlayback }

    public mutating func userPlay() {
        intent.userPlay()
    }

    /// The user pressed pause, including during a DJ break. Music must not restart when speech ends.
    @discardableResult
    public mutating func userPause() -> AudioSessionDirective {
        intent.userPause()
        return .suspendPlayback
    }

    /// `breakIsActive` is true while the state machine is in `.transition` or `.voice`.
    /// An interruption that ends during a break does not resume here; the break asks again when it ends.
    @discardableResult
    public mutating func handle(_ notice: AudioSessionNotice, breakIsActive: Bool) -> AudioSessionDirective {
        switch notice {
        case .interruptionBegan:
            interruptionOngoing = true
            intent.systemInterruptionBegan()
            return .suspendPlayback
        case .interruptionEnded(let shouldResume):
            interruptionOngoing = false
            intent.systemInterruptionEnded(shouldResume: shouldResume)
            guard !breakIsActive, intent.mayAutoResume else { return .none }
            return .resumeIfPermitted
        case .routeChanged(.oldDeviceUnavailable):
            intent.routeRemoved()
            return .suspendPlayback
        case .routeChanged(.other):
            return .none
        }
    }
}

extension AudioSessionPolicy {
    /// Build 18 P0 (-Fry): called once at a natural-end boundary (before the break or song 2
    /// starts) and again when song 2 is about to load. Releases the interruption hold only when
    /// `SongEndHold.releases` says so. A route hold and a user pause are never released.
    /// Returns true when it released a hold.
    @discardableResult
    public mutating func naturalEndReached(interruptionBeganNearEnd: Bool, otherAudioPlaying: Bool,
                                           secondaryHint: Bool, callActive: Bool) -> Bool {
        guard intent.pausedBySystem else { return false }
        guard SongEndHold.releases(interruptionEnded: !interruptionOngoing,
                                   otherAudioPlaying: otherAudioPlaying,
                                   secondaryHint: secondaryHint,
                                   callActive: callActive,
                                   beganNearEnd: interruptionBeganNearEnd) else { return false }
        let before = intent
        intent.releaseInterruptionHoldAtSongEnd()
        return intent != before
    }
}

/// Build 18 P0 (-Fry, gates from Sentinel, Echo, Atlas, Orion). The one rule for whether a system
/// interruption that began at the end of a song may keep holding the next song (and its break).
///
/// The theory (unconfirmed on device): as `ApplicationMusicPlayer`'s one-song queue finishes, the
/// shared session gets `interruptionBegan` with no matching end, and song 2 is held forever.
/// The hold is released only when the interruption began in the end window AND no call is
/// active AND either the interruption has ended, or nothing else is playing
/// (`isOtherAudioPlaying == false` and `secondaryAudioShouldBeSilencedHint == false`).
/// A real call, or another app's audio, keeps song 2 held.
public enum SongEndHold {
    public static func releases(interruptionEnded: Bool, otherAudioPlaying: Bool, secondaryHint: Bool,
                                callActive: Bool, beganNearEnd: Bool) -> Bool {
        guard beganNearEnd, !callActive else { return false }
        if interruptionEnded { return true }
        return !otherAudioPlaying && !secondaryHint
    }
}

/// `AVAudioSessionInterruptionReasonKey`, reduced to a log-safe enum. Raw values are mapped in
/// Core so the app passes the UInt and no SDK availability check is needed. Enum only, no text.
public enum AudioInterruptionReason: String, Equatable, Sendable, CaseIterable {
    case `default`
    case appWasSuspended
    case builtInMicMuted
    case routeDisconnected
    case unknown

    /// `nil` when the key is absent (older systems omit it).
    public init(rawReason: UInt?) {
        switch rawReason {
        case 0?: self = .default
        case 1?: self = .appWasSuspended
        case 2?: self = .builtInMicMuted
        case 4?: self = .routeDisconnected
        default: self = .unknown
        }
    }
}

/// Observer installation is once per service, including when session activation fails and is retried.
public struct SessionRegistrationGate: Equatable, Sendable {
    public private(set) var isRegistered = false

    public init() {}

    /// True only on the first call.
    public mutating func registerIfNeeded() -> Bool {
        if isRegistered { return false }
        isRegistered = true
        return true
    }
}
