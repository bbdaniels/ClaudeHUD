import Foundation
import Security
import os

private let logger = Logger(subsystem: "com.claudehud", category: "Keychain")

// MARK: - Keychain Errors

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed: \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
        case .deleteFailed(let status):
            return "Keychain delete failed: \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
        case .encodingFailed:
            return "Failed to encode API key as UTF-8 data"
        }
    }
}

// MARK: - Keychain Service

enum KeychainService {
    private static let service = "com.claudehud.api-key"
    private static let account = "anthropic"

    /// Save the API key to the Keychain. Overwrites any existing value.
    static func save(apiKey: String) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Delete any existing item first (ignore errors -- it may not exist)
        try? delete()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            logger.error("Keychain save failed: \(status)")
            throw KeychainError.saveFailed(status)
        }

        logger.info("API key saved to Keychain")
    }

    /// Load the API key from the Keychain. Returns nil if not found.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.warning("Keychain load returned unexpected status: \(status)")
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete the API key from the Keychain.
    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Keychain delete failed: \(status)")
            throw KeychainError.deleteFailed(status)
        }

        logger.info("API key deleted from Keychain")
    }
}
