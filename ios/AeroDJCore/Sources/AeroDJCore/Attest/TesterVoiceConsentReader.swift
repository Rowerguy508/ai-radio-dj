import Foundation

/// The tester voice's consent check (#378 §4) over Nova's existing `CloudVoiceConsentStore`
/// (#258), not a second consent model: the tester sheet writes the same stored answer with
/// `accept()` / `decline()`, and `InstallTokenSource` reads it through `PaidVoiceConsentProviding`
/// before any Keychain, device or network call. A wrapper rather than
/// `extension CloudVoiceConsentStore: PaidVoiceConsentProviding {}`, because #258 declares that
/// conformance itself and a second one would not compile once both land. -Atlas
public struct TesterVoiceConsentReader: PaidVoiceConsentProviding {
    public let store: CloudVoiceConsentStore

    public init(_ store: CloudVoiceConsentStore) { self.store = store }

    /// Reads the store on every call, so a decline applies to the next cue.
    public func hasPaidVoiceConsent() async -> Bool { store.isGranted }

    /// The tester sheet is offered only while the stored answer is undecided (never answered,
    /// swiped away, or accepted an older copy version).
    public var shouldOfferSheet: Bool { store.state == .undecided }
}
