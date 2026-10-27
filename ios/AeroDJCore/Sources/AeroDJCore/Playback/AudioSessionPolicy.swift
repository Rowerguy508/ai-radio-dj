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
            intent.systemInterruptionBegan()
            return .suspendPlayback
        case .interruptionEnded(let shouldResume):
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
