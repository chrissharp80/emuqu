import Foundation
import Security

/// Stores and retrieves third-party AI provider API keys in the iOS Keychain.
///
/// Keys are device-local (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
/// never synced to iCloud, never written to disk in plaintext. One entry per
/// provider, keyed by `ProviderID`.
///
/// Singleton because there's only ever one keychain.
/// Stateless: every call goes to the Keychain, so it is `Sendable`.
final class APIKeyStore: Sendable {
    static let shared = APIKeyStore()

    private static let service = "com.chrissharp.flowrecovery.assistant.apikey"

    private init() {}

    // MARK: - Public API

    /// Returns the stored key for a provider, or nil if none.
    func key(for provider: ProviderID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: provider.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else {
            return nil
        }
        return key
    }

    /// True when a key exists for this provider.
    func hasKey(for provider: ProviderID) -> Bool {
        key(for: provider) != nil
    }

    /// Stores or replaces the key for a provider.
    /// Empty/whitespace strings are treated as a delete.
    ///
    /// Tries an update first and falls back to an insert, which is the only
    /// way to distinguish "replace an existing key" from "store a new one"
    /// through the Keychain's C API.
    @discardableResult
    func setKey(_ key: String?, for provider: ProviderID) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return removeKey(for: provider) }
        guard let data = trimmed.data(using: .utf8) else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: provider.rawValue
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        return add(attributes, to: baseQuery)
    }

    /// No existing item to update — insert one instead.
    private func add(_ attributes: [CFString: Any], to baseQuery: [CFString: Any]) -> Bool {
        var addQuery = baseQuery
        for (k, v) in attributes {
            addQuery[k] = v
        }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the key for a provider.
    @discardableResult
    func removeKey(for provider: ProviderID) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: provider.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Removes every stored key for every known provider.
    ///
    /// Returns whether EVERY deletion succeeded. Used by "Delete All My Data",
    /// which reports the outcome to the user.
    ///
    /// Each result must be checked, not discarded with `_ = removeKey(...)`,
    /// and `DataPurgeService` must not hardcode `keychainCleared: true`:
    /// otherwise a Keychain failure — the item locked by device state, an OS
    /// error — is reported to the user as "AI provider keys: removed" while
    /// the key is still on the device. Telling someone their
    /// credentials are gone when they are not is the worst direction for this
    /// to be wrong in.
    ///
    /// Every provider is attempted even after one fails: a partial wipe should
    /// remove as much as it can, and the caller needs to know it was partial,
    /// not stop at the first problem.
    @discardableResult
    func removeAllKeys() -> Bool {
        var allSucceeded = true
        for provider in ProviderID.allCases where !removeKey(for: provider) {
            debugLog("[APIKeyStore] failed to remove key for \(provider.rawValue)", level: .error)
            allSucceeded = false
        }
        if !removeServiceKey(for: .tavilyWebSearch) {
            debugLog("[APIKeyStore] failed to remove the web-search service key", level: .error)
            allSucceeded = false
        }
        return allSucceeded
    }

    // MARK: - Non-AI service keys (web search, etc.)
    //
    // Some integrations need their own API key without being an AI provider.
    // Tavily (web search) is the first example. Stored in the same keychain
    // service but under a distinct account namespace so they don't collide
    // with AI provider keys (which are keyed by `ProviderID.rawValue`).
    //
    // Adding a new service key = one new case in `ServiceKeyID` + one
    // optional accessor pair below.

    enum ServiceKeyID: String, CaseIterable {
        /// Tavily search API — used by the web-search action in the
        /// fact catalog. https://tavily.com (free tier 1000 searches/mo).
        case tavilyWebSearch = "service.tavily_web_search"
    }

    func serviceKey(for service: ServiceKeyID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: service.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    func hasServiceKey(for service: ServiceKeyID) -> Bool {
        serviceKey(for: service) != nil
    }

    @discardableResult
    func setServiceKey(_ key: String?, for service: ServiceKeyID) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return removeServiceKey(for: service) }
        guard let data = trimmed.data(using: .utf8) else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: service.rawValue
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    func removeServiceKey(for service: ServiceKeyID) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: service.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func maskedServicePreview(for service: ServiceKeyID) -> String? {
        guard let key = serviceKey(for: service) else { return nil }
        guard key.count > 8 else { return String(repeating: "•", count: max(key.count, 4)) }
        return "•••••\(key.suffix(4))"
    }

    /// Convenience for showing the user a masked preview of their saved key
    /// (e.g., "sk-ant-•••••wxyz") without exposing the full secret.
    func maskedPreview(for provider: ProviderID) -> String? {
        guard let key = key(for: provider) else { return nil }
        guard key.count > 8 else { return String(repeating: "•", count: max(key.count, 4)) }
        let suffix = key.suffix(4)
        return "•••••\(suffix)"
    }
}
