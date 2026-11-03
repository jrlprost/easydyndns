import Foundation
import Security

/// The Cloudflare API token lives only in the macOS login Keychain.
public enum Keychain {
    static let service = "EasyDynDNS"
    static let account = "cloudflare-api-token"

    static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    public static func saveToken(_ token: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrLabel as String] = "EasyDynDNS Cloudflare API token"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw AppError("Could not save the token in the Keychain (OSStatus \(status)).") }
    }

    public static func deleteToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
