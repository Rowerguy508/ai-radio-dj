import Foundation
#if canImport(Security)
import Security
#endif

// The app's install ID for App Attest register (Atlas's #270 contract, -Fry):
// a random UUID v4, made once on this install, kept in a this-device-only Keychain item,
// sent as the lowercase 36-character `installId` on POST /api/attest/register only.
// It carries no device data (no model, name, vendor ID or advertising ID) and is never logged.

/// What a storage read found. Only `.notFound` may lead to creating an ID (Atlas N1, #277):
/// any other read error (e.g. `errSecInteractionNotAllowed` before first unlock) leaves the item
/// alone and register fails quietly.
public enum AttestInstallIDRead: Equatable, Sendable { case found(String), notFound, failed }

/// What adding the item did. `.duplicate`: one already exists (another caller won), re-read it.
public enum AttestInstallIDAdd: Equatable, Sendable { case added, duplicate, failed }

/// Raw storage for the install ID. Injectable: Linux tests use `InMemoryAttestInstallIDStorage`,
/// the app uses `KeychainAttestInstallIDStorage`. It never deletes the item.
public protocol AttestInstallIDStorage: Sendable {
    func readInstallID() -> AttestInstallIDRead
    /// Adds the item only if there is none.
    func addInstallID(_ value: String) -> AttestInstallIDAdd
    /// Overwrites an existing item in place (an invalid stored value). Returns whether it did.
    func replaceInstallID(_ value: String) -> Bool
}

/// In-process storage (tests, and platforms without a Keychain).
public final class InMemoryAttestInstallIDStorage: AttestInstallIDStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    /// Test hooks: a read error, failing writes, or a read-back that differs from what was written.
    public var readFails = false
    private let failsWrites: Bool
    private let readBack: String?
    public init(_ value: String? = nil, failsWrites: Bool = false, readBack: String? = nil) {
        self.value = value; self.failsWrites = failsWrites; self.readBack = readBack
    }
    /// The raw stored value (tests).
    public var stored: String? { lock.withLock { value } }
    public func readInstallID() -> AttestInstallIDRead {
        lock.withLock {
            if readFails { return .failed }
            guard let value else { return .notFound }
            return .found(readBack ?? value)
        }
    }
    public func addInstallID(_ value: String) -> AttestInstallIDAdd {
        lock.withLock {
            if failsWrites { return .failed }
            if self.value != nil { return .duplicate }
            self.value = value
            return .added
        }
    }
    public func replaceInstallID(_ value: String) -> Bool {
        lock.withLock {
            guard !failsWrites, self.value != nil else { return false }
            self.value = value
            return true
        }
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

    /// The attributes `addInstallID` adds the item with.
    static func addAttributes(_ value: String) -> [String: Any] {
        var q = query()
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = accessibility
        return q
    }

    public func readInstallID() -> AttestInstallIDRead {
        var q = Self.query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        return Self.read(status: status, data: out as? Data)
    }

    /// Maps a read status: only `errSecItemNotFound` is `.notFound`; every other error is
    /// `.failed` (never a reason to create or overwrite the item).
    static func read(status: OSStatus, data: Data?) -> AttestInstallIDRead {
        switch status {
        case errSecSuccess:
            guard let data, let value = String(data: data, encoding: .utf8) else { return .failed }
            return .found(value)
        case errSecItemNotFound: return .notFound
        default: return .failed
        }
    }

    public func addInstallID(_ value: String) -> AttestInstallIDAdd {
        switch SecItemAdd(Self.addAttributes(value) as CFDictionary, nil) {
        case errSecSuccess: return .added
        case errSecDuplicateItem: return .duplicate
        default: return .failed
        }
    }

    public func replaceInstallID(_ value: String) -> Bool {
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                     kSecAttrAccessible as String: Self.accessibility]
        return SecItemUpdate(Self.query() as CFDictionary, update as CFDictionary) == errSecSuccess
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
/// A read error other than "not found" (e.g. before first unlock) returns nil and changes
/// nothing. If it can't be stored, `current()` returns nil (register then fails quietly) rather than
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

    /// The app's one install ID: the Keychain item (in-memory where there is no Keychain).
    /// A single shared instance (Sentinel N2, #277): its lock is the one every caller goes
    /// through, so two first-run callers can't each create a different ID.
    public static let shared: AttestInstallID = {
        #if canImport(Security)
        AttestInstallID(storage: KeychainAttestInstallIDStorage())
        #else
        AttestInstallID(storage: InMemoryAttestInstallIDStorage())
        #endif
    }()

    /// The shared instance (never a new one).
    public static func live() -> AttestInstallID { shared }

    /// One creation at a time (two first calls get one ID). Create only when the read says
    /// `.notFound`; a read error returns nil and touches nothing. Every write is read back.
    public func current() -> AttestInstallIdentifier? {
        lock.withLock {
            switch storage.readInstallID() {
            case .failed:
                return nil
            case .found(let stored) where AttestInstallIdentifier.isValid(stored):
                return AttestInstallIdentifier(rawValue: stored)
            case .found:
                let fresh = makeID()
                guard let fresh, storage.replaceInstallID(fresh) else { return nil }
                return readBack(expecting: fresh)
            case .notFound:
                guard let fresh = makeID() else { return nil }
                switch storage.addInstallID(fresh) {
                case .added: return readBack(expecting: fresh)
                case .duplicate: return readBack(expecting: nil)
                case .failed: return nil
                }
            }
        }
    }

    private func makeID() -> String? {
        let fresh = generate().uuidString.lowercased()
        return AttestInstallIdentifier.isValid(fresh) ? fresh : nil
    }

    /// The stored ID after a write: it must be valid and, when `expecting` is set, the value written.
    private func readBack(expecting: String?) -> AttestInstallIdentifier? {
        guard case .found(let stored) = storage.readInstallID(), AttestInstallIdentifier.isValid(stored),
              expecting.map({ $0 == stored }) ?? true else { return nil }
        return AttestInstallIdentifier(rawValue: stored)
    }
}
