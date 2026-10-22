import Foundation
import Observation
import PartsKit
import Security

/// Secrets in the Keychain. Saved as iCloud Keychain items where the build allows it, so keys typed on the Mac
/// reach the iPhone and iPad; a build without that entitlement (an ad-hoc signed Mac build) keeps them on the device.
nonisolated enum KeychainStore {
    static let service = "com.hitorro.PartsInventory.suppliers"

    private static func base(_ account: String, synced: Bool) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if synced {
            q[kSecUseDataProtectionKeychain] = true
            q[kSecAttrSynchronizable] = kCFBooleanTrue
        }
        return q
    }

    enum Read { case value(String), missing, failed(OSStatus) }

    /// The item, or whether it's missing or couldn't be read (access denied, keychain locked) — which matters
    /// before replacing it.
    static func read(_ account: String) -> Read {
        var failure: OSStatus?
        for synced in [true, false] {
            var q = base(account, synced: synced)
            q[kSecReturnData] = true
            q[kSecMatchLimit] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecSuccess, let d = out as? Data { return .value(String(decoding: d, as: UTF8.self)) }
            if status != errSecItemNotFound, status != errSecMissingEntitlement { failure = failure ?? status }
        }
        return failure.map { .failed($0) } ?? .missing
    }

    static func get(_ account: String) -> String {
        if case .value(let v) = read(account) { return v }
        return ""
    }

    static func set(_ value: String, for account: String) {
        for synced in [true, false] { SecItemDelete(base(account, synced: synced) as CFDictionary) }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        for synced in [true, false] {
            var q = base(account, synced: synced)
            q[kSecValueData] = Data(v.utf8)
            q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return }
            // errSecMissingEntitlement and friends: try the plain, this-device-only item.
        }
    }
}

/// The supplier API keys, and a lookup that uses them.
@Observable
final class SupplierKeys {
    static let shared = SupplierKeys()

    private(set) var digikeyID: String
    private(set) var digikeySecret: String
    private(set) var mouserKey: String
    /// Rebuilt when the keys change, so Digi-Key's sign-in is reused between lookups.
    private(set) var lookup: SupplierLookup

    private init() {
        let id = KeychainStore.get("digikey.clientID"), secret = KeychainStore.get("digikey.clientSecret"), key = KeychainStore.get("mouser.apiKey")
        digikeyID = id; digikeySecret = secret; mouserKey = key
        lookup = SupplierLookup(digikeyID: id, digikeySecret: secret, mouserKey: key)
    }

    var isConfigured: Bool { lookup.isConfigured }

    func save(digikeyID: String, digikeySecret: String, mouserKey: String) {
        let id = digikeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = digikeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = mouserKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if id != self.digikeyID { KeychainStore.set(id, for: "digikey.clientID"); self.digikeyID = id }
        if secret != self.digikeySecret { KeychainStore.set(secret, for: "digikey.clientSecret"); self.digikeySecret = secret }
        if key != self.mouserKey { KeychainStore.set(key, for: "mouser.apiKey"); self.mouserKey = key }
        lookup = SupplierLookup(digikeyID: id, digikeySecret: secret, mouserKey: key)
    }
}
