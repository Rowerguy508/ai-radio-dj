import Foundation

/// Orion P1 on #125 (-Atlas): replaying deferred session notices must be scoped to the attempt
/// they were deferred for. The old replay ran every notice in an unstructured `Task`, so attempt
/// A's `.began` could pause attempt B, and A's `.ended` could resume after B had started.
///
/// Now every notice updates the policy and performs its suspend synchronously, on the main
/// actor, at flush time, while the origin attempt is still current (the gate drops deferred
/// notices on a new start, so a flush always belongs to the current attempt). A real hold
/// (call, route, the user's pause) therefore applies at once to the current attempt.
/// The only step that needs to await is a resume. It runs only through a `ResumeTicket`, which
/// is valid only while the origin attempt is still current, no call is active and the policy
/// still allows an automatic resume. A later suspend in the same batch cancels an earlier resume.
public struct DeferredInterruptionReplay: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let notice: AudioSessionNotice
        /// The policy's directive. A `.resumeIfPermitted` here is never performed directly:
        /// only `resume` may start playback.
        public let directive: AudioSessionDirective
    }

    public struct ResumeTicket: Equatable, Sendable {
        public let origin: PlaybackAttemptID

        /// Checked when the resume actually runs, after any hop.
        public func mayResume(current: PlaybackAttemptID?, callActive: Bool,
                              policy: AudioSessionPolicy) -> Bool {
            origin == current && !callActive && policy.mayAutoResume
        }
    }

    public let origin: PlaybackAttemptID?
    public let steps: [Step]
    public let resume: ResumeTicket?

    /// Applies `notices` to `policy` in arrival order and returns what to perform now.
    public static func run(_ notices: [AudioSessionNotice], origin: PlaybackAttemptID?,
                           policy: inout AudioSessionPolicy, breakIsActive: Bool) -> DeferredInterruptionReplay {
        var steps: [Step] = []
        var wantsResume = false
        for notice in notices {
            let directive = policy.handle(notice, breakIsActive: breakIsActive)
            steps.append(Step(notice: notice, directive: directive))
            switch directive {
            case .suspendPlayback: wantsResume = false
            case .resumeIfPermitted: wantsResume = true
            case .none: break
            }
        }
        let ticket = (wantsResume ? origin : nil).map(ResumeTicket.init(origin:))
        return DeferredInterruptionReplay(origin: origin, steps: steps, resume: ticket)
    }
}
