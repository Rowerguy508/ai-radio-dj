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

    /// The first copy version that discloses that every DJ line is sent (owner, Nov 9 2026:
    /// "I want it all elevenlabs."). Version 1 said personal items never leave the device.
    public static let allLinesVersion = 2

    /// What `VoiceRenderer` may send off the device (`VoiceRenderer.cloudScope`): every attributed
    /// line once copy v2 or later is accepted, nothing otherwise. An acceptance of v1 reads
    /// `.undecided` (asked again) and so sends nothing, not even the v1 transitions, until the
    /// listener accepts the new copy. Read straight from the store on every call. -Fry
    public var scope: CloudVoiceScope {
        isGranted && Self.currentVersion >= Self.allLinesVersion ? .allLines : .noLines
    }

    /// Same shape as `PaidVoiceConsentProviding.hasPaidVoiceConsent()` in Fry's #244, so the
    /// stacked paywall PR adds only `extension CloudVoiceConsentStore: PaidVoiceConsentProviding {}`.
    /// Reads the store on every call (no caching), so a decline is seen by the very next check.
    public func hasPaidVoiceConsent() async -> Bool { isGranted }

    /// "Use cloud voice". The only way to grant.
    public func accept() { write(.accepted) }

    /// "Keep on-device voice", or the toggle turned off. Takes effect on the next render.
    public func decline() { write(.declined) }
}

extension VoiceRenderer {
    /// This renderer with its cloud scope read from `store` on every cue (`CloudVoiceConsentStore.scope`):
    /// `.allLines` after copy v2 is accepted, `.noLines` for v1 only, undecided, declined or off.
    /// The tester and owner A/B builds both build their live renderer this way (#433). -Fry
    public func gated(by store: CloudVoiceConsentStore) -> VoiceRenderer {
        VoiceRenderer(routes: routes, budget: budget, cache: cache, revocations: revocations,
                      cloudScope: { store.scope })
    }
}

/// When the sheet must be shown. A cloud voice is offered only when the build allows paid
/// voices and one is selected; the sheet then appears until the listener answers. A decline is
/// not asked again automatically; the Cloud voice toggle asks again when turned on.
public enum CloudVoiceConsentPrompt {
    public static func isCloudVoiceOffered(paidProvidersEnabled: Bool, selectedVoiceID: String?) -> Bool {
        paidProvidersEnabled && selectedVoiceID != nil
    }

    /// The same question with the build flags passed in, so every combination is testable on
    /// Linux (Sentinel's N1 on #395, -Nova):
    /// - `AERODJ_OWNER_AB` (owner A/B): unchanged, a paid provider enabled and a voice selected.
    ///   It wins over the tester flag, because the tester voice is compiled only as
    ///   `AERODJ_TESTER_VOICE && !AERODJ_OWNER_AB`.
    /// - `AERODJ_TESTER_VOICE` alone (internal TestFlight tester build): always offered. The
    ///   tester route falls back to the catalog's first voice (`TesterVoice.voiceID`), so no
    ///   selection is needed, and testers must be able to turn the cloud voice off.
    /// - Neither flag (Debug, Release, App Store): never offered, whatever else is passed.
    public static func isCloudVoiceOffered(ownerABBuild: Bool, testerVoiceBuild: Bool,
                                           paidProvidersEnabled: Bool, selectedVoiceID: String?) -> Bool {
        if ownerABBuild { return isCloudVoiceOffered(paidProvidersEnabled: paidProvidersEnabled, selectedVoiceID: selectedVoiceID) }
        return testerVoiceBuild
    }

    /// `isCloudVoiceOffered` for the build this module was compiled as.
    public static func isCloudVoiceOfferedInThisBuild(selectedVoiceID: String?) -> Bool {
        isCloudVoiceOffered(ownerABBuild: OwnerVoiceTrial.paidProvidersEnabled, testerVoiceBuild: TesterVoice.enabled,
                            paidProvidersEnabled: OwnerVoiceTrial.paidProvidersEnabled, selectedVoiceID: selectedVoiceID)
    }

    public static func shouldPresent(cloudVoiceOffered: Bool, state: CloudVoiceConsentState) -> Bool {
        cloudVoiceOffered && state == .undecided
    }
}

/// Sheet copy, from docs/privacy/disclosure-copy.md §1 (#174, draft), with the app name from
/// `AppName.display`. Version 2 (owner, Nov 9 2026: "I want it all elevenlabs."): every DJ line,
/// personal items and news/weather included, is sent (`CloudVoiceScope.allLines`). Owner-pending
/// items are left out, not invented: ElevenLabs retention/training wording, and the app's own
/// Privacy Policy URL.
public enum CloudVoiceConsentCopy {
    /// Version of the copy below. A material change must bump it (asks everyone again).
    /// 1: transitions only (#176). 2: every DJ line (`CloudVoiceConsentStore.allLinesVersion`).
    public static let version = 2

    public static let title = "Use a cloud voice?"
    public static var intro: String {
        "This voice is generated online, not on your iPhone. To speak each DJ break, \(AppName.display) sends the words of that break to our voice server, and on to ElevenLabs, which turns them into audio."
    }
    public static let sentHeading = "What's sent:"
    public static let sent = "the text of everything the DJ says. That includes your personal items: calendar events, your shared email digest and other shared items, notes, songs from your music library and the station names you type. It also includes the news and weather lines."
    public static let neverSentHeading = "What's never sent:"
    public static let neverSent = "your Apple ID, your contacts, your coordinates or your location itself, or anything you haven't approved for your briefing. Only the words the DJ speaks are sent, and a local news line can name your city or area."
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
    public static let footer = "Cloud voice: everything the DJ says, including your calendar, shared items, notes, library songs, news and weather, is sent to ElevenLabs to make audio. On-device voices never leave your iPhone."
    public static let toggleTitle = "Cloud voice"
}
