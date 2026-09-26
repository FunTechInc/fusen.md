import Foundation
import Security

/// Where the Notion token is kept. A protocol so tests never touch the real Keychain.
@MainActor
protocol NotionTokenStore: AnyObject {
    func readToken() -> String?
    func saveToken(_ token: String) throws
    func deleteToken()
    /// Whether a token is saved, without reading it (which can bring up a Keychain prompt).
    func containsToken() -> Bool
}

extension NotionTokenStore {
    func containsToken() -> Bool { readToken() != nil }
}

/// The Notion token as a generic password in the login Keychain
/// (service "<bundle id>.notion", account "api-token"), readable only on this Mac and only after
/// the first unlock. It is never written anywhere else and never shown in the UI. Debug builds
/// (`swift run`) use "<bundle id>.debug.notion", as they use their own notes folder, so they never
/// send test notes with the real token.
///
/// The app is ad-hoc signed, so every rebuild has a new code signature; the first read after a
/// rebuild may make macOS ask whether fusen.md may use the item ("常に許可" stops the
/// question until the next rebuild).
@MainActor
final class KeychainTokenStore: NotionTokenStore {
    let service: String
    let account = "api-token"

    init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    static var defaultService: String {
        #if DEBUG
        service(bundleIdentifier: Bundle.main.bundleIdentifier, debug: true)
        #else
        service(bundleIdentifier: Bundle.main.bundleIdentifier, debug: false)
        #endif
    }

    /// `swift run` has no bundle identifier; the app's is "com.github.funtechinc.fusen-md".
    static func service(bundleIdentifier: String?, debug: Bool) -> String {
        (bundleIdentifier ?? "com.github.funtechinc.fusen-md") + (debug ? ".debug" : "") + ".notion"
    }

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
            return "Keychain error \(status) \(message)"
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func readToken() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Asks for the item's attributes only: macOS asks for permission to read the secret, not these.
    func containsToken() -> Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "fusen.md – Notion"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func deleteToken() {
        SecItemDelete(query as CFDictionary)
    }
}
