import Foundation
#if canImport(Security)
import Security
#endif

// The app's install ID for App Attest register (Atlas's #270 contract, -Fry):
// a random UUID v4, made once on this install, kept in a this-device-only Keychain item,
// sent as the lowercase 36-character `installId` on POST /api/attest/register only.
// It carries no device data (no model, name, vendor ID or advertising ID) and is never logged.

/// Raw storage for the install ID. Injectable: Linux tests use `InMemoryAttestInstallIDStorage`,
/// the app uses `KeychainAttestInstallIDStorage`.
public protocol AttestInstallIDStorage: Sendable {
    func readInstallID() -> String?
    /// Stores `value`, replacing any previous one. Returns whether it was stored.
    func writeInstallID(_ value: String) -> Bool
}

/// In-process storage (tests, and platforms without a Keychain).
public final class InMemoryAttestInstallIDStorage: AttestInstallIDStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private let failsWrites: Bool
    public init(_ value: String? = nil, failsWrites: Bool = false) { self.value = value; self.failsWrites = failsWrites }
    public func readInstallID() -> String? { lock.withLock { value } }
    public func writeInstallID(_ value: String) -> Bool {
        lock.withLock { if !failsWrites { self.value = value }; return !failsWrites }
    }
}

/// The Keychain item that holds the install ID. `AfterFirstUnlockThisDeviceOnly` and not
/// synchronizable: never in a backup or iCloud Keychain, never moved to another device, and
/// readable in the background after the first unlock.
public enum AttestInstallIDKeychain {
    public static let service = "com.aerodj.attest.install-id"
    public static let account = "installId"
    /// The `kSecAttrAccessible` constant's name, for platform-neutral tests.
    public static let accessibilityName = "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
}

#if canImport(Security)
/// The live storage: the Keychain item described by `AttestInstallIDKeychain`.
public struct KeychainAttestInstallIDStorage: AttestInstallIDStorage {
    /// Must match `AttestInstallIDKeychain.accessibilityName` (checked by AttestInstallIDTests).
    public static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    public init() {}

    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AttestInstallIDKeychain.service,
         kSecAttrAccount as String: AttestInstallIDKeychain.account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    /// The attributes `writeInstallID` adds the item with.
    static func addAttributes(_ value: String) -> [String: Any] {
        var q = query()
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = accessibility
        return q
    }

    public func readInstallID() -> String? {
        var q = Self.query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func writeInstallID(_ value: String) -> Bool {
        SecItemDelete(Self.query() as CFDictionary)
        return SecItemAdd(Self.addAttributes(value) as CFDictionary, nil) == errSecSuccess
    }
}
#endif

/// The install ID as sent. Its descriptions are redacted, so string interpolation, `print`,
/// `dump` or a log line can't show the value; only the register body reads `rawValue`.
public struct AttestInstallIdentifier: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    let rawValue: String
    public var description: String { "installId(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Atlas's server check (#270): lowercase UUID v4, exactly 36 characters.
    public static func isValid(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        return value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                           options: .regularExpression) != nil
    }
}

/// Makes the install ID once and returns the same one after that (also across launches,
/// through the storage). A stored value that isn't a valid lowercase v4 is replaced.
/// If it can't be stored, `current()` returns nil (register then fails quietly) rather than
/// sending an ID that would change on every launch.
public final class AttestInstallID: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: any AttestInstallIDStorage
    private let generate: @Sendable () -> UUID

    /// `generate` is `UUID.init` (random, v4) except in tests.
    public init(storage: any AttestInstallIDStorage, generate: @escaping @Sendable () -> UUID = { UUID() }) {
        self.storage = storage
        self.generate = generate
    }

    /// The app's install ID: the Keychain item (in-memory where there is no Keychain).
    public static func live() -> AttestInstallID {
        #if canImport(Security)
        AttestInstallID(storage: KeychainAttestInstallIDStorage())
        #else
        AttestInstallID(storage: InMemoryAttestInstallIDStorage())
        #endif
    }

    public func current() -> AttestInstallIdentifier? {
        lock.withLock {
            if let stored = storage.readInstallID(), AttestInstallIdentifier.isValid(stored) {
                return AttestInstallIdentifier(rawValue: stored)
            }
            let fresh = generate().uuidString.lowercased()
            guard AttestInstallIdentifier.isValid(fresh), storage.writeInstallID(fresh),
                  storage.readInstallID() == fresh else { return nil }
            return AttestInstallIdentifier(rawValue: fresh)
        }
    }
}
