import Foundation

// appAccountToken (Atlas, #233 §5.4): every Pro purchase passes `.appAccountToken(uuid)` so the
// proxy can tie Apple's signed transaction to this install. The UUID is random, made once, kept in
// the Keychain (never UserDefaults), and reused on every later purchase and launch. It is
// never logged and never sent anywhere else by the app. -Nova

/// Where the token lives. The app's store is the Keychain (`KeychainAppAccountTokenStore`).
public protocol AppAccountTokenStoring: Sendable {
    func read() -> UUID?
    /// False when the write failed.
    @discardableResult func write(_ token: UUID) -> Bool
}

public struct AppAccountTokenProvider: Sendable {
    private let store: any AppAccountTokenStoring
    private let make: @Sendable () -> UUID

    public init(store: any AppAccountTokenStoring, make: @escaping @Sendable () -> UUID = { UUID() }) {
        self.store = store
        self.make = make
    }

    /// The stored token, or a new random one, stored before it's returned.
    public func token() -> UUID {
        if let existing = store.read() { return existing }
        let fresh = make()
        store.write(fresh)
        // If the write failed, use what the store holds now, if anything (another writer won).
        return store.read() ?? fresh
    }
}

/// Purchase options for a Pro purchase, StoreKit-free. The app maps each case to
/// `Product.PurchaseOption`.
public enum ProPurchaseOption: Equatable, Sendable {
    case appAccountToken(UUID)
}

public enum ProPurchasePlan {
    public static func options(token: UUID) -> [ProPurchaseOption] { [.appAccountToken(token)] }
}

/// For tests and previews. A shared instance stands in for the Keychain across "launches".
public final class InMemoryAppAccountTokenStore: AppAccountTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?
    public private(set) var writes = 0

    public init(_ value: UUID? = nil) { self.value = value }

    public func read() -> UUID? { lock.withLock { value } }

    @discardableResult public func write(_ token: UUID) -> Bool {
        lock.withLock { value = token; writes += 1 }
        return true
    }
}
