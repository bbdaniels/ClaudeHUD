import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SecretsVault")

/// In-memory secrets cache backed by a single Touch ID-protected Keychain item.
///
/// Call `unlock()` once at app launch to trigger a single Touch ID prompt. After
/// that, all reads are synchronous in-memory lookups — no further prompts, even
/// after rebuilds with new ad-hoc signatures. Writes update both the cache and
/// the Keychain (no prompt on write).
///
/// This replaces the previous scheme of per-credential Keychain items, each with
/// its own ACL that prompted separately on every signature change.
final class SecretsVault: @unchecked Sendable {
    static let shared = SecretsVault()

    struct Secrets: Codable {
        var anthropicKey: String?
        var claudeAiCookie: String?
        var substackCookie: String?
    }

    private let lock = NSLock()
    private var cached: Secrets?

    private static let service = "com.claudehud.vault"
    private static let account = "secrets"
    private static let migrationKey = "com.claudehud.vault.migrated.v1"

    private init() {}

    /// True after `unlock()` has completed.
    var isUnlocked: Bool {
        lock.withLock { cached != nil }
    }

    /// Read a cached secret. Returns nil if the vault has not been unlocked
    /// or the value is unset.
    func read(_ keyPath: KeyPath<Secrets, String?>) -> String? {
        lock.withLock { cached?[keyPath: keyPath] }
    }

    /// Update a secret and persist to Keychain.
    func write(_ keyPath: WritableKeyPath<Secrets, String?>, _ value: String?) {
        let snapshot: Secrets = lock.withLock {
            var s = cached ?? Secrets()
            s[keyPath: keyPath] = value
            cached = s
            return s
        }
        persist(snapshot)
    }

    /// Unlock the vault by reading from Keychain. Triggers Touch ID once.
    /// On first run, migrates legacy per-service items into the new vault.
    func unlock() async {
        if isUnlocked { return }

        let migrated = UserDefaults.standard.bool(forKey: Self.migrationKey)

        if !migrated {
            NSLog("[SecretsVault] Running one-time migration from legacy keychain items")
            let (legacy, readFailed) = Self.loadLegacySecrets()
            lock.withLock { cached = legacy }
            let persisted = persist(legacy)
            if persisted && !readFailed {
                Self.deleteLegacyItems()
                UserDefaults.standard.set(true, forKey: Self.migrationKey)
                NSLog("[SecretsVault] Migration complete — legacy items deleted")
            } else {
                NSLog("[SecretsVault] Migration incomplete (persisted=\(persisted), readFailed=\(readFailed)) — legacy items preserved")
            }
            return
        }

        let loaded = await Self.loadFromKeychain()
        lock.withLock { cached = loaded ?? Secrets() }
    }

    // MARK: - Keychain I/O

    /// Persist the full secrets blob to Keychain. Returns true on success.
    @discardableResult
    private func persist(_ secrets: Secrets) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else {
            NSLog("[SecretsVault] Failed to encode secrets")
            return false
        }

        // Classic keychain — the only option without a provisioning profile.
        // Item gets an ACL bound to the calling binary's signature; user sees
        // one password prompt per rebuild (ad-hoc signatures change each build).
        // "Always Allow" holds until the next rebuild.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[SecretsVault] SecItemAdd failed: \(status)")
            return false
        }
        NSLog("[SecretsVault] Vault item saved successfully")
        return true
    }

    private static func loadFromKeychain() async -> Secrets? {
        await Task.detached { () -> Secrets? in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: SecretsVault.service,
                kSecAttrAccount as String: SecretsVault.account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else {
                if status != errSecItemNotFound {
                    NSLog("[SecretsVault] Vault load failed: \(status)")
                }
                return nil
            }
            return try? JSONDecoder().decode(Secrets.self, from: data)
        }.value
    }

    // MARK: - Legacy Migration

    private static let legacyItems: [(service: String, account: String)] = [
        ("com.claudehud.api-key", "anthropic"),
        ("com.claudehud.claudeai", "sessionKey"),
        ("com.claudehud.substack", "substack.sid"),
    ]

    /// Reads legacy items. Returns secrets plus `readFailed` flag indicating
    /// whether any existing item could not be read (user canceled prompt, etc.).
    /// A missing item is not a failure.
    private static func loadLegacySecrets() -> (secrets: Secrets, readFailed: Bool) {
        var readFailed = false

        func readLegacy(service: String, account: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                // User canceled prompt, auth failed, or other error — do not
                // proceed with deletion.
                logger.warning("Legacy item \(service)/\(account) unreadable: \(status)")
                readFailed = true
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        let secrets = Secrets(
            anthropicKey: readLegacy(service: legacyItems[0].service, account: legacyItems[0].account),
            claudeAiCookie: readLegacy(service: legacyItems[1].service, account: legacyItems[1].account),
            substackCookie: readLegacy(service: legacyItems[2].service, account: legacyItems[2].account)
        )
        return (secrets, readFailed)
    }

    private static func deleteLegacyItems() {
        for item in legacyItems {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: item.service,
                kSecAttrAccount as String: item.account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
