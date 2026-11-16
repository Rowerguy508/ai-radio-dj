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
///
/// #441 (-Sentinel): the answer and the copy version it answers are one value, `recordKey`
/// ("<version>:<state>", e.g. "2:accepted"), read with one `string(forKey:)` and written with one
/// `set`. Every reader sees a whole old record or a whole new one, never a state from one write
/// paired with a version from another, so a decline can never pass through "v2 + accepted".
/// The two-key layout before 2.0 (`stateKey`, `versionKey`) is legacy and is only ever read
/// conservatively (`legacyState`): a legacy decline stays a decline, and a legacy acceptance of
/// any version, v2 included, reads `.undecided`, because "accepted + v2" is exactly the shape a
/// torn v1-accept-then-v2-decline left behind and its provenance cannot be proven. Existing
/// testers who accepted v2 under the old layout are therefore asked once more; nothing is sent
/// until they tap "Use cloud voice" again. The next write removes the legacy keys.
public struct CloudVoiceConsentStore: @unchecked Sendable {
    /// The single atomic record: "<copy version>:<state raw value>".
    public static let recordKey = "AeroDJ.cloudVoiceConsent.record"
    /// Legacy (before #441): read only by the fail-closed migration, removed on the next write.
    public static let stateKey = "AeroDJ.cloudVoiceConsent.state"
    /// Legacy (before #441): read only by the fail-closed migration, removed on the next write.
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
        if let memory { return Self.decode(memory.read()) }
        guard let defaults else { return .undecided }
        // One read of one key: the record is never assembled from two reads.
        if let record = defaults.object(forKey: Self.recordKey) {
            return Self.decode(record as? String)
        }
        return Self.legacyState(defaults)
    }

    /// The stored record for `state` at the current copy version.
    public static func encode(_ state: CloudVoiceConsentState, version: Int = currentVersion) -> String {
        "\(version):\(state.rawValue)"
    }

    /// Strict, fail-closed parse of a record. Anything that is not exactly "<version>:<state>",
    /// with a canonical non-negative version and a known state, reads `.undecided`. An acceptance
    /// counts only for the current copy version (older or newer reads `.undecided`). A decline of
    /// any version stays a decline.
    public static func decode(_ record: String?) -> CloudVoiceConsentState {
        guard let record else { return .undecided }
        let parts = record.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let version = Int(parts[0]), version >= 0, String(version) == parts[0],
              let stored = CloudVoiceConsentState(rawValue: String(parts[1])) else { return .undecided }
        switch stored {
        case .accepted: return version == currentVersion ? .accepted : .undecided
        case .declined, .undecided: return stored
        }
    }

    /// The two-key layout before #441, read so a legacy decline is kept. Never grants: the two
    /// keys may be from different writes (a torn decline leaves "accepted" with the new version).
    static func legacyState(_ defaults: UserDefaults) -> CloudVoiceConsentState {
        guard let raw = defaults.string(forKey: stateKey),
              let stored = CloudVoiceConsentState(rawValue: raw) else { return .undecided }
        return stored == .declined ? .declined : .undecided
    }

    private func write(_ state: CloudVoiceConsentState) {
        let record = Self.encode(state)
        if let memory {
            memory.write(record)
        } else if let defaults {
            defaults.set(record, forKey: Self.recordKey)       // the one write that decides
            // Legacy keys are ignored once the record exists, and never grant anyway.
            defaults.removeObject(forKey: Self.stateKey)
            defaults.removeObject(forKey: Self.versionKey)
        }
    }

    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var record: String?
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return record }
        func write(_ record: String) { lock.lock(); self.record = record; lock.unlock() }
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
