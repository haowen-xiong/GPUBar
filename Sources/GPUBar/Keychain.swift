import Foundation
import Security
import LocalAuthentication
import GPUBarCore

@MainActor enum Keychain {
    static let service = "io.github.haowen-xiong.GPUBar.platform-credentials"
    static func load(_ platform: Platform) throws -> Credentials? {
        // The file-based macOS keychain does not honor LAContext's UI policy.
        // Keep this synchronous and main-actor isolated so background polling
        // fails promptly instead of opening an authorization dialog.
        let interactionStatus = SecKeychainSetUserInteractionAllowed(false)
        guard interactionStatus == errSecSuccess else { throw KeychainError(status: interactionStatus) }
        defer { SecKeychainSetUserInteractionAllowed(true) }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: platform.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    static func save(_ credentials: Credentials, platform: Platform) throws {
        guard credentials.isValid else { throw CloudError.credentials }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: platform.rawValue]
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credentials),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
    static func delete(_ platform: Platform) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: platform.rawValue]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "钥匙串暂不可访问（\(status)）。请解锁钥匙串，或在设置中重新保存凭据。" }
}
