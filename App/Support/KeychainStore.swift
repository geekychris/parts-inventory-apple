import Foundation
import Observation
import PartsKit
import Security
import Synchronization

/// Secrets in the Keychain, all in one item (a small JSON dictionary) that's read once per launch: macOS asks
/// for the keychain password per item whenever the app's signature isn't one the item trusts, so one item means
/// at most one question. Saved as an iCloud Keychain item where the build allows it, so keys typed on the Mac
/// reach the iPhone and iPad; a build without that entitlement keeps it on the device.
///
/// Older builds kept each secret in its own item; those are moved into the dictionary the first time each is
/// read, and left in place (deleting them would ask again).
nonisolated enum KeychainStore {
    static let service = "com.hitorro.PartsInventory.suppliers"
    private static let bundleAccount = "secrets"
    private static let legacyAccounts: Set<String> = ["digikey.clientID", "digikey.clientSecret", "mouser.apiKey", "api.token"]

    private enum Loaded { case values([String: String]), failed(OSStatus) }
    private static let cache = Mutex<Loaded?>(nil)

    private static func base(_ account: String, synced: Bool) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if synced {
            q[kSecUseDataProtectionKeychain] = true
            q[kSecAttrSynchronizable] = kCFBooleanTrue
        }
        return q
    }

    enum Read { case value(String), missing, failed(OSStatus) }

    /// One raw item, synced first.
    private static func readItem(_ account: String) -> Read {
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

    private static func writeItem(_ value: String, for account: String) {
        for synced in [true, false] { SecItemDelete(base(account, synced: synced) as CFDictionary) }
        guard !value.isEmpty else { return }
        for synced in [true, false] {
            var q = base(account, synced: synced)
            q[kSecValueData] = Data(value.utf8)
            q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return }
            // errSecMissingEntitlement and friends: try the plain, this-device-only item.
        }
    }

    /// The dictionary, read from the Keychain the first time only. A refusal is remembered too, so a denied
    /// request isn't repeated for every secret.
    private static func loaded() -> Loaded {
        cache.withLock { c in
            if let c { return c }
            let l: Loaded
            switch readItem(bundleAccount) {
            case .value(let json):
                l = .values((try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:])
            case .missing: l = .values([:])
            case .failed(let s): l = .failed(s)
            }
            c = l
            return l
        }
    }

    private static func save(_ values: [String: String]) {
        let json = (try? JSONEncoder().encode(values)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        writeItem(values.isEmpty ? "" : json, for: bundleAccount)
        cache.withLock { $0 = .values(values) }
    }

    /// The secret, or whether it's missing or couldn't be read (access denied, keychain locked) — which matters
    /// before replacing it.
    static func read(_ account: String) -> Read {
        var values: [String: String]
        switch loaded() {
        case .failed(let s): return .failed(s)
        case .values(let v): values = v
        }
        if let v = values[account] { return .value(v) }
        guard legacyAccounts.contains(account) else { return .missing }
        let old = readItem(account)
        if case .value(let v) = old {
            values[account] = v
            save(values)
        }
        return old
    }

    static func get(_ account: String) -> String {
        if case .value(let v) = read(account) { return v }
        return ""
    }

    static func set(_ value: String, for account: String) {
        // Never overwrite a dictionary that couldn't be read: the other secrets in it would be lost.
        guard case .values(var values) = loaded() else { return }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { values[account] = nil } else { values[account] = v }
        save(values)
    }
}

/// The supplier API keys, and a lookup that uses them.
@Observable
final class SupplierKeys {
    static let shared = SupplierKeys()

    private(set) var digikeyID: String
    private(set) var digikeySecret: String
    private(set) var mouserKey: String
    /// For the order lists: Digi-Key's customer account number, and Mouser's Order History API key.
    private(set) var digikeyAccount: String
    private(set) var mouserOrderKey: String
    /// Rebuilt when the keys change, so Digi-Key's sign-in is reused between lookups.
    private(set) var lookup: SupplierLookup

    private init() {
        let id = KeychainStore.get("digikey.clientID"), secret = KeychainStore.get("digikey.clientSecret"), key = KeychainStore.get("mouser.apiKey")
        digikeyID = id; digikeySecret = secret; mouserKey = key
        digikeyAccount = KeychainStore.get("digikey.accountID"); mouserOrderKey = KeychainStore.get("mouser.orderKey")
        lookup = SupplierLookup(digikeyID: id, digikeySecret: secret, mouserKey: key)
    }

    var isConfigured: Bool { lookup.isConfigured }

    /// Which suppliers' order histories can be listed.
    var canListDigiKeyOrders: Bool { lookup.digikey != nil && !digikeyAccount.isEmpty }
    var canListMouserOrders: Bool { !mouserOrderKey.isEmpty }

    func digikeyOrders(since: Date) async throws -> [OrderSummary] {
        guard let dk = lookup.digikey else { throw SupplierError("digikey", "Add your Digi-Key client ID and secret in Settings.") }
        return try await dk.orders(accountID: digikeyAccount, since: since)
    }

    var mouserOrders: MouserOrdersClient { MouserOrdersClient(apiKey: mouserOrderKey) }

    func save(digikeyID: String, digikeySecret: String, mouserKey: String, digikeyAccount: String? = nil, mouserOrderKey: String? = nil) {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let id = trim(digikeyID), secret = trim(digikeySecret), key = trim(mouserKey)
        if id != self.digikeyID { KeychainStore.set(id, for: "digikey.clientID"); self.digikeyID = id }
        if secret != self.digikeySecret { KeychainStore.set(secret, for: "digikey.clientSecret"); self.digikeySecret = secret }
        if key != self.mouserKey { KeychainStore.set(key, for: "mouser.apiKey"); self.mouserKey = key }
        if let a = digikeyAccount.map(trim), a != self.digikeyAccount { KeychainStore.set(a, for: "digikey.accountID"); self.digikeyAccount = a }
        if let k = mouserOrderKey.map(trim), k != self.mouserOrderKey { KeychainStore.set(k, for: "mouser.orderKey"); self.mouserOrderKey = k }
        lookup = SupplierLookup(digikeyID: id, digikeySecret: secret, mouserKey: key)
    }
}
