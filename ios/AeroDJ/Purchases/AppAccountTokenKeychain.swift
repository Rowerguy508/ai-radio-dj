import AeroDJCore
import Foundation
import Security

/// The appAccountToken's home: one generic-password Keychain item, this device only, readable
/// after first unlock (purchases can happen from a background restore). Not UserDefaults, and
/// not synced to iCloud Keychain. The token is not a secret credential (Apple returns it inside
/// the signed transaction); it is kept here so it survives app updates and is never logged. -Nova
struct KeychainAppAccountTokenStore: AppAccountTokenStoring {
    static let service = "com.aerodj.app.appAccountToken"
    static let account = "pro"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    func read() -> UUID? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }

    @discardableResult func write(_ token: UUID) -> Bool {
        var q = query
        q[kSecValueData as String] = Data(token.uuidString.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Add only: an existing token is never overwritten (the provider reads first).
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
