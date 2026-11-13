import Foundation

/// #400 (-Sentinel): the privacy class of one DJ cue, decided in one place (`CuePrivacy.classify`)
/// from the cue and its attribution. Every route that leaves the device or is paid asks
/// `mayLeaveDevice(scope:)` with the live consent scope right before it reads the cache, calls
/// the provider and writes the cache (`VoiceRenderer.mayUse(_:for:)`), and the briefing
/// rewrite step asks it before a segment reaches a rewriter that leaves the device.
/// Fail-closed: anything the classifier does not recognise is `.onDeviceOnly`.
public enum CuePrivacyClass: String, Equatable, Sendable, CaseIterable {
    /// Never leaves the device, whatever the consent: a cue with no attribution.
    case onDeviceOnly
    /// Personal or listener-derived: briefing items (calendar, shared items, notes), library or
    /// unknown-origin tracks, typed station names, sourced lines and provider facts (news,
    /// weather). Leaves the device only with consent to the all-lines copy (v3, `.allLines`).
    case personal
    /// A non-personal DJ transition (presenter phrasing or catalog track metadata) with no
    /// source, source item or provenance. Allowed by the transitions-only scope (#176) and v3.
    case `public`

    /// Whether a cue of this class may go to a route that leaves the device or is paid under `scope`.
    public func mayLeaveDevice(scope: CloudVoiceScope) -> Bool {
        switch (self, scope) {
        case (.onDeviceOnly, _), (_, .noLines): return false
        case (.personal, .allLines), (.public, .allLines), (.public, .transitionsOnly): return true
        case (.personal, .transitionsOnly): return false
        }
    }
}

public enum CuePrivacy {
    /// The class of `cue` spoken with `attribution`. Same rule as #176 / #432: no attribution is
    /// on-device only; `.personalContext`, `.stationName` and non-catalog track metadata are
    /// personal; presenter or catalog lines are public only when the cue is a plain transition
    /// with no source item, source kind or provenance (anything else, a fact line included, is
    /// personal).
    public static func classify(_ cue: NarrationCue, attribution: SpokenAttribution?) -> CuePrivacyClass {
        guard let attribution else { return .onDeviceOnly }
        switch attribution {
        case .personalContext, .stationName: return .personal
        case .trackMetadata(_, let origin): guard origin == .catalog else { return .personal }
        case .presenter: break
        }
        let plainTransition = cue.kind == .transition && !cue.isContent && cue.source == nil && cue.provenance == nil
        return plainTransition ? .public : .personal
    }

    /// The class of a briefing segment before the rewrite (generation) step: a plain transition
    /// with no source item, source kind or provenance is public; every other segment is personal.
    public static func classify(_ segment: BriefingScriptSegment) -> CuePrivacyClass {
        let plainTransition = segment.kind == .transition && segment.sourceItemID == nil
            && segment.source == nil && segment.provenance == nil
        return plainTransition ? .public : .personal
    }
}
