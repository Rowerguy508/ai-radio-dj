import Foundation
#if canImport(Security)
import Security
#endif

// Where the registered App Attest key ID lives (#378, -Atlas).
//
// Only a key the server answered 204 for is saved. A key that was generated or attested but not
// registered is simply dropped: an attestation is bound to a 120 s challenge and Apple allows one
// attestation per key, so it can't be re-sent later. A dropped Secure Enclave key costs nothing.
// The key ID is a Device ID in the App Privacy answers (#378 §4.2); it is never logged.

/// What a key ID read found. `.failed` (e.g. before first unlock) is not `.notFound`: the source
/// does not enroll a new key on a read error, it just uses the on-device voice for that cue.
public enum AttestKeyIDRead: Equatable, Sendable { case found(String), notFound, failed }

public protocol AttestKeyIDStorage: Sendable {
    func readKeyID() -> AttestKeyIDRead
    /// Adds or replaces the one stored key ID. Returns whether it was written.
    func saveKeyID(_ keyId: String) -> Bool
    /// Removes the stored key ID (invalidated key, server `reattest`).
    func clearKeyID()
}

/// App Attest key IDs are standard base64 of a 32-byte SHA-256: 43 characters plus one `=`
/// (server `parseKeyId`, challenge.ts). Anything else is never sent.
public enum AttestKeyID {
    public static func isValid(_ value: String) -> Bool {
        guard value.utf8.count == 44, value.hasSuffix("="),
              value.range(of: "^[A-Za-z0-9+/]{43}=$", options: .regularExpression) != nil,
              let raw = Data(base64Encoded: value), raw.count == 32 else { return false }
        return raw.base64EncodedString() == value
    }
}

/// In-process storage (Linux tests, and platforms without a Keychain).
public final class InMemoryAttestKeyIDStorage: AttestKeyIDStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var failsReads = false
    public init(_ value: String? = nil) { self.value = value }
    /// Test hook: every read fails.
    public var readFails: Bool {
        get { lock.withLock { failsReads } }
        set { lock.withLock { failsReads = newValue } }
    }
    public var stored: String? { lock.withLock { value } }
    public func readKeyID() -> AttestKeyIDRead {
        lock.withLock {
            if failsReads { return .failed }
            return value.map { .found($0) } ?? .notFound
        }
    }
    public func saveKeyID(_ keyId: String) -> Bool { lock.withLock { value = keyId; return true } }
    public func clearKeyID() { lock.withLock { value = nil } }
}

/// The Keychain item for the key ID: this device only, after first unlock, never synchronized,
/// so it never reaches a backup or another device (a restored device must attest again anyway).
public enum AttestKeyIDKeychain {
    public static let service = "com.aerodj.attest.key-id"
    public static let account = "keyId"
    public static let accessibilityName = "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"
}

#if canImport(Security)
public struct KeychainAttestKeyIDStorage: AttestKeyIDStorage {
    public static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
    public init() {}

    static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AttestKeyIDKeychain.service,
         kSecAttrAccount as String: AttestKeyIDKeychain.account,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    public func readKeyID() -> AttestKeyIDRead {
        var q = Self.query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess:
            guard let data = out as? Data, let value = String(data: data, encoding: .utf8) else { return .failed }
            return .found(value)
        case errSecItemNotFound: return .notFound
        default: return .failed
        }
    }

    public func saveKeyID(_ keyId: String) -> Bool {
        let update: [String: Any] = [kSecValueData as String: Data(keyId.utf8),
                                     kSecAttrAccessible as String: Self.accessibility]
        switch SecItemUpdate(Self.query() as CFDictionary, update as CFDictionary) {
        case errSecSuccess: return true
        case errSecItemNotFound:
            var add = Self.query()
            add[kSecValueData as String] = Data(keyId.utf8)
            add[kSecAttrAccessible as String] = Self.accessibility
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        default: return false
        }
    }

    public func clearKeyID() { SecItemDelete(Self.query() as CFDictionary) }
}
#endif
