import Foundation
import Security

/// The sync sign-in token, kept in the login keychain.
enum Keychain {
    static let syncTokenAccount = "supabase-refresh-token"
    private static let service = "LearnDesk"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Saves the value; an empty string removes it. Returns false if the keychain refused.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        SecItemDelete(baseQuery(account) as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
