import Foundation
import Security

public struct KeychainAccessError: Error, LocalizedError, Sendable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
    public var errorDescription: String? { L10n.translate("Keychain access unavailable (\(status)). Use Unlock in SubscriptionBar to allow access.") }
}

/// Never queue a second operation behind a user permission dialog.
final class KeychainInteractionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let setAllowed: @Sendable (Bool) throws -> Void
    init(setAllowed: @escaping @Sendable (Bool) throws -> Void) { self.setAllowed = setAllowed }
    func perform<T>(allowUserInteraction: Bool, operation: () throws -> T) throws -> T {
        guard lock.try() else { throw KeychainAccessError(status: errSecInteractionNotAllowed) }
        defer { lock.unlock() }
        do { try setAllowed(allowUserInteraction) }
        catch { try? setAllowed(false); throw error }
        let result = Result { try operation() }
        try setAllowed(false)
        return try result.get()
    }
}

private struct SystemKeychainStorage: RawVaultStoring {
    func read(service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        try KeychainVault.read(service: service, account: account, allowUserInteraction: allowUserInteraction)
    }
    func write(service: String, account: String, data: Data, allowUserInteraction: Bool) throws {
        try KeychainVault.write(service: service, account: account, data: data, allowUserInteraction: allowUserInteraction)
    }
}

public struct KeychainVault: SecretStoring {
    public let service: String
    private let storage: SingleRecordVault
    private static let interactionGate = KeychainInteractionGate { allowed in
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        guard status == errSecSuccess else { throw KeychainAccessError(status: status) }
    }
    public init(service: String = "com.local.subscriptionbar.vault", root: URL? = nil) {
        self.service = service
        storage = SingleRecordVault(service: service,
            root: root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SubscriptionBar"),
            raw: SystemKeychainStorage())
    }
    public func read(_ key: String) throws -> Data? { try storage.read(key) }
    public func write(_ key: String, data: Data) throws { try storage.write(key, data: data) }
    public func remove(_ key: String) throws { try storage.remove(key) }
    public func authorize() throws -> Bool { try storage.authorize() }
    public func status() -> VaultStatus { storage.status() }
    public func importEntries(_ entries: [String: Data]) throws { try storage.importEntries(entries) }

    public static func disableAutomaticInteraction() throws {
        try withInteractionPolicy(allowUserInteraction: false) {}
    }
    public static func withInteractionPolicy<T>(allowUserInteraction: Bool = false, operation: () throws -> T) throws -> T {
        try interactionGate.perform(allowUserInteraction: allowUserInteraction, operation: operation)
    }
    public static func read(service: String, account: String, allowUserInteraction: Bool = false) throws -> Data? {
        try withInteractionPolicy(allowUserInteraction: allowUserInteraction) {
            let query = readQuery(service: service, account: account, allowUserInteraction: allowUserInteraction)
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainAccessError(status: status) }
            guard let data = result as? Data else { throw KeychainAccessError(status: errSecDecode) }
            return data
        }
    }
    public static func write(service: String, account: String, data: Data, allowUserInteraction: Bool = false) throws {
        try withInteractionPolicy(allowUserInteraction: allowUserInteraction) {
            let query = writeQuery(service: service, account: account, allowUserInteraction: allowUserInteraction)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var addition = query
                addition[kSecValueData as String] = data
                addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let added = SecItemAdd(addition as CFDictionary, nil)
                guard added == errSecSuccess else { throw KeychainAccessError(status: added) }
            } else if status != errSecSuccess { throw KeychainAccessError(status: status) }
        }
    }
    static func readQuery(service: String, account: String, allowUserInteraction: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowUserInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return query
    }
    static func writeQuery(service: String, account: String, allowUserInteraction: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if !allowUserInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return query
    }
    public static func claudeServices() throws -> [String] {
        try withInteractionPolicy {
            // Enumerate attributes only; no password values and no authentication UI.
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess else { throw KeychainAccessError(status: status) }
            return (result as? [[String: Any]] ?? []).compactMap { item in
                guard let service = item[kSecAttrService as String] as? String,
                      item[kSecAttrAccount as String] as? String == NSUserName(),
                      service == "Claude Code-credentials" || service.hasPrefix("Claude Code-credentials-") else { return nil }
                return service
            }.sorted()
        }
    }
}
