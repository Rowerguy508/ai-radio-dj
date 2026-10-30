import Foundation
#if canImport(Security)
import Security
#endif

/// The listener's answer to "Are you 18 or older?", asked before the cloud-voice consent sheet
/// (Orion + owner, 2026-10-29: Pro voice is 18+, the app stays 13+). There is no default answer:
/// `.unanswered` is not a yes, so it keeps the listener on the on-device voice.
public enum PaidVoiceAgeAnswer: String, Equatable, Sendable, CaseIterable {
    case unanswered, adult, notAdult

    /// Only an explicit yes confirms the age.
    public var isAdultConfirmed: Bool { self == .adult }
}

/// Where the age answer comes from. Must answer `.unanswered` until the listener answered, and
/// reflect a change (or a cleared answer) on the next read. Synchronous and on-device only.
public protocol PaidVoiceAgeProviding: Sendable {
    func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer
}

/// Fail-closed default: never answered.
public struct NoPaidVoiceAgeAnswer: PaidVoiceAgeProviding {
    public init() {}
    public func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer { .unanswered }
}

/// Raw storage for the age answer (one optional string). Injectable so Linux tests use
/// `InMemoryPaidVoiceAgeStorage`; the app uses `KeychainPaidVoiceAgeStorage` (Sentinel N2, #267).
public protocol PaidVoiceAgeStorage: Sendable {
    func readAnswer() -> String?
    /// `nil` deletes the stored answer.
    func writeAnswer(_ value: String?)
}

/// In-process storage (tests, and platforms without a Keychain). Lost on relaunch.
public final class InMemoryPaidVoiceAgeStorage: PaidVoiceAgeStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func readAnswer() -> String? { lock.withLock { value } }
    public func writeAnswer(_ value: String?) { lock.withLock { self.value = value } }
}

/// Where the live answer is kept: one generic-password Keychain item on this device only.
/// `AfterFirstUnlockThisDeviceOnly`: never in a backup or iCloud Keychain, never migrated to
/// another device, and still readable while the phone is locked with the DJ playing (a read that
/// failed while locked would silently drop the cloud voice). Not synchronizable.
public enum PaidVoiceAgeKeychain {
    public static let service = "com.aerodj.paid-voice.age"
    public static let account = "answer"
    /// The `kSecAttrAccessible` constant's name, for platform-neutral tests and logs.
    public static let accessibilityName = "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
}

#if canImport(Security)
/// The live storage: the Keychain item described by `PaidVoiceAgeKeychain`.
public struct KeychainPaidVoiceAgeStorage: PaidVoiceAgeStorage {
    /// Must match `PaidVoiceAgeKeychain.accessibilityName` (checked by PaidVoiceAgeGateTests).
    public static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    public init() {}

    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: PaidVoiceAgeKeychain.service,
         kSecAttrAccount as String: PaidVoiceAgeKeychain.account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    /// The attributes `writeAnswer` adds the item with.
    static func addAttributes(_ value: String) -> [String: Any] {
        var q = query()
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = accessibility
        return q
    }

    public func readAnswer() -> String? {
        var q = Self.query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func writeAnswer(_ value: String?) {
        SecItemDelete(Self.query() as CFDictionary)
        guard let value else { return }
        SecItemAdd(Self.addAttributes(value) as CFDictionary, nil)
    }
}
#endif

/// The on-device store for the age answer. Never sent anywhere, never in a backup.
/// This is the read/write API for the "Are you 18 or older?" step (Nova builds the UI).
/// After `record(isAdult:)` or `clear()`, the caller calls `DJBreakSession.paidVoiceAccessChanged()`
/// exactly as it does after a consent change: a "no" or a cleared answer drops prepared cloud
/// breaks at once, and a "yes" lets the next break use the cloud voice (no relaunch).
public struct PaidVoiceAgeStore: PaidVoiceAgeProviding {
    private static let yes = "yes", no = "no"
    private let storage: any PaidVoiceAgeStorage

    /// No default storage: callers say where the answer lives (tests: in-memory).
    public init(storage: any PaidVoiceAgeStorage) { self.storage = storage }

    /// The app's store: the Keychain item (`PaidVoiceAgeKeychain`). Without a Keychain
    /// (Linux), in-memory, so the answer is never written anywhere that is backed up.
    public static var live: PaidVoiceAgeStore {
        #if canImport(Security)
        PaidVoiceAgeStore(storage: KeychainPaidVoiceAgeStorage())
        #else
        PaidVoiceAgeStore(storage: InMemoryPaidVoiceAgeStorage())
        #endif
    }

    /// The stored answer. Missing or unrecognised values read as `.unanswered`.
    public var answer: PaidVoiceAgeAnswer {
        switch storage.readAnswer() {
        case Self.yes?: return .adult
        case Self.no?: return .notAdult
        default: return .unanswered
        }
    }

    public var isAdultConfirmed: Bool { answer.isAdultConfirmed }

    public func paidVoiceAgeAnswer() -> PaidVoiceAgeAnswer { answer }

    /// The listener's explicit answer: `true` for "yes, 18 or older", `false` for "no".
    public func record(isAdult: Bool) { storage.writeAnswer(isAdult ? Self.yes : Self.no) }

    /// Withdraws the answer (back to `.unanswered`, which is not confirmed).
    public func clear() { storage.writeAnswer(nil) }
}

extension ProVoiceAccess {
    /// This gate with the age check in front of it: unless `age` answers `.adult` at the moment
    /// of the lookup, the decision is `.denied(.ageNotConfirmed)` and the inner gate (consent,
    /// then Pro) is not even asked. `PaidVoice.publicComposition` applies it to the access it
    /// returns, so the per-cue check, the take re-check and bundled clips all see the age.
    public func requiringAdult(_ age: any PaidVoiceAgeProviding) -> ProVoiceAccess {
        let inner = self
        return ProVoiceAccess(deciding: {
            guard age.paidVoiceAgeAnswer().isAdultConfirmed else { return .denied(.ageNotConfirmed) }
            return await inner.decision()
        })
    }
}
