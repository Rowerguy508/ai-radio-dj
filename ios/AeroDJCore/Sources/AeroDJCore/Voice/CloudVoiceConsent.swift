import Foundation

/// The listener's answer to the cloud-voice disclosure (docs/privacy/disclosure-copy.md §1).
/// Anything other than an accepted answer to the current copy version counts as "no".
public enum CloudVoiceConsentState: String, Equatable, Sendable {
    /// Never answered, dismissed without answering, or accepted an older copy version.
    case undecided
    case accepted
    /// "Keep on-device voice", or the Cloud voice toggle turned off.
    case declined
}

/// Persisted cloud-voice consent, versioned so a material copy change asks again.
///
/// The core gate: `VoiceRenderer.render` reads `isGranted` before every route that is not
/// local and free, per cue, so no DJ text reaches a cloud or paid voice until "Use cloud voice"
/// is stored, and turning it off applies to the very next render. Reads go straight to
/// `UserDefaults` (thread-safe), so every copy of this store agrees. Fail-closed: a missing,
/// unknown or older-version value reads as `.undecided`, which is not granted. -Nova
public struct CloudVoiceConsentStore: @unchecked Sendable {
    public static let stateKey = "AeroDJ.cloudVoiceConsent.state"
    public static let versionKey = "AeroDJ.cloudVoiceConsent.version"
    /// Bump when the sheet copy changes materially: earlier acceptances then read `.undecided`.
    public static let currentVersion = CloudVoiceConsentCopy.version

    private let defaults: UserDefaults?
    private let memory: MemoryBox?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.memory = nil
    }

    private init(memory: MemoryBox) {
        self.defaults = nil
        self.memory = memory
    }

    /// A store that persists nothing, for tests, previews and fixtures. Copies share state.
    public static func inMemory(_ state: CloudVoiceConsentState = .undecided) -> CloudVoiceConsentStore {
        let store = CloudVoiceConsentStore(memory: MemoryBox())
        switch state {
        case .accepted: store.accept()
        case .declined: store.decline()
        case .undecided: break
        }
        return store
    }

    public var state: CloudVoiceConsentState {
        let raw: String?
        let version: Int
        if let memory {
            (raw, version) = memory.read()
        } else if let defaults {
            raw = defaults.string(forKey: Self.stateKey)
            version = defaults.integer(forKey: Self.versionKey)
        } else {
            return .undecided
        }
        guard let raw, let stored = CloudVoiceConsentState(rawValue: raw) else { return .undecided }
        switch stored {
        case .accepted:
            // Consent covers only the copy the listener saw.
            return version == Self.currentVersion ? .accepted : .undecided
        case .declined, .undecided:
            return stored
        }
    }

    private func write(_ state: CloudVoiceConsentState) {
        if let memory {
            memory.write(state.rawValue, Self.currentVersion)
        } else if let defaults {
            defaults.set(Self.currentVersion, forKey: Self.versionKey)
            defaults.set(state.rawValue, forKey: Self.stateKey)
        }
    }

    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: String?
        private var version = 0
        func read() -> (String?, Int) { lock.lock(); defer { lock.unlock() }; return (raw, version) }
        func write(_ raw: String, _ version: Int) { lock.lock(); self.raw = raw; self.version = version; lock.unlock() }
    }

    /// True only for an accepted answer to the current copy version.
    public var isGranted: Bool { state == .accepted }

    /// Same shape as `PaidVoiceConsentProviding.hasPaidVoiceConsent()` in Fry's #244, so the
    /// stacked paywall PR adds only `extension CloudVoiceConsentStore: PaidVoiceConsentProviding {}`.
    /// Reads the store on every call (no caching), so a decline is seen by the very next check.
    public func hasPaidVoiceConsent() async -> Bool { isGranted }

    /// "Use cloud voice". The only way to grant.
    public func accept() { write(.accepted) }

    /// "Keep on-device voice", or the toggle turned off. Takes effect on the next render.
    public func decline() { write(.declined) }
}

/// When the sheet must be shown. A cloud voice is offered only when the build allows paid
/// voices and one is selected; the sheet then appears until the listener answers. A decline is
/// not asked again automatically; the Cloud voice toggle asks again when turned on.
public enum CloudVoiceConsentPrompt {
    public static func isCloudVoiceOffered(paidProvidersEnabled: Bool, selectedVoiceID: String?) -> Bool {
        paidProvidersEnabled && selectedVoiceID != nil
    }

    public static func shouldPresent(cloudVoiceOffered: Bool, state: CloudVoiceConsentState) -> Bool {
        cloudVoiceOffered && state == .undecided
    }
}

/// Sheet copy, verbatim from docs/privacy/disclosure-copy.md §1 (#174, draft), with the app
/// name from `AppName.display`. Owner-pending items are left out, not invented: the
/// briefing clause (briefing cues never leave the device, `VoiceRenderer.mayLeaveDevice`),
/// ElevenLabs retention/training wording, and the app's own Privacy Policy URL.
public enum CloudVoiceConsentCopy {
    /// Version of the copy below. A material change must bump it (asks everyone again).
    public static let version = 1

    public static let title = "Use a cloud voice?"
    public static var intro: String {
        "This voice is generated online, not on your iPhone. To speak each DJ break, \(AppName.display) sends the words of that break to our voice server, and on to ElevenLabs, which turns them into audio."
    }
    public static let sentHeading = "What's sent:"
    public static let sent = "only the text the DJ is about to say, such as song and artist names, your station's name, and time-of-day lines."
    public static let neverSentHeading = "What's never sent:"
    public static let neverSent = "your Apple ID, your contacts, your location, your music library when a station is built from your library (those stations always use the on-device voice), or anything you haven't approved for your briefing."
    public static let storedHeading = "How it's stored:"
    public static let stored = "our server keeps a short technical log without the text. ElevenLabs may keep the text and audio under its own privacy policy."
    public static let switchBack = "You can switch back to the on-device voice at any time in Settings."
    public static let accept = "Use cloud voice"
    public static let decline = "Keep on-device voice"
    public static let privacyPolicyLabel = "Privacy Policy"
    /// Owner-pending: no URL yet, so the link is not shown.
    public static let privacyPolicyURL: URL? = nil
    public static let elevenLabsPolicyLabel = "ElevenLabs Privacy Policy"
    public static let elevenLabsPolicyURL = URL(string: "https://elevenlabs.io/privacy-policy")!
    /// Short footer under the Cloud voice toggle (§1 "Short footer").
    public static let footer = "Cloud voice: the DJ's words are sent to ElevenLabs to make audio. On-device voices never leave your iPhone."
    public static let toggleTitle = "Cloud voice"
}
