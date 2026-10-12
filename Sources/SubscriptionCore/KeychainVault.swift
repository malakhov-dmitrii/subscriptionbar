import Foundation
import LocalAuthentication
import Security

public struct KeychainAccessError: Error, LocalizedError, Sendable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
    public var errorDescription: String? { L10n.translate("Keychain operation failed (\(status)).") }
    public var needsUserAuthorization: Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed || status == errSecInteractionRequired
    }
}

public struct KeychainItemSelector: Equatable, Hashable, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String?
    public let useDataProtectionKeychain: Bool
    public init(service: String, account: String, accessGroup: String? = nil,
                useDataProtectionKeychain: Bool = false) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }
}

public enum KeychainAuthorizationTarget: Equatable, Hashable, Sendable {
    case subscriptionVault
    case claudeCode(KeychainItemSelector)
}

public struct KeychainAuthorizationError: Error, LocalizedError, Equatable, Sendable {
    public let target: KeychainAuthorizationTarget
    public let status: Int32
    public init(target: KeychainAuthorizationTarget, status: Int32) {
        self.target = target
        self.status = status
    }
    public var errorDescription: String? { L10n.translate("Keychain approval is required (\(status)).") }
}

public struct KeychainPromptInProgressError: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { L10n.tr("A Keychain approval request is already in progress.") }
}

public struct KeychainItemSnapshot: Equatable, Sendable {
    public let selector: KeychainItemSelector
    public let persistentReference: Data
    public let data: Data
}

public enum KeychainVerificationResult: Equatable, Sendable {
    case verified, missing, invalid, changed
}

final class KeychainPromptGate: @unchecked Sendable {
    private let lock = NSLock()
    func perform<T>(_ operation: () throws -> T) throws -> T {
        guard lock.try() else { throw KeychainPromptInProgressError() }
        defer { lock.unlock() }
        return try operation()
    }
}

public struct KeychainClient: Sendable {
    public typealias SnapshotReader = @Sendable (KeychainItemSelector, Data?, Bool) throws -> KeychainItemSnapshot?
    public typealias Writer = @Sendable (KeychainItemSelector, Data) throws -> Void

    private let snapshotReader: SnapshotReader
    private let writer: Writer
    private let promptGate: KeychainPromptGate
    public let usesSystemAuthorizationHelper: Bool

    init(snapshotReader: @escaping SnapshotReader, writer: @escaping Writer,
         promptGate: KeychainPromptGate = KeychainPromptGate(),
         usesSystemAuthorizationHelper: Bool = false) {
        self.snapshotReader = snapshotReader
        self.writer = writer
        self.promptGate = promptGate
        self.usesSystemAuthorizationHelper = usesSystemAuthorizationHelper
    }

    public static let system = KeychainClient(
        snapshotReader: KeychainClient.systemSnapshot,
        writer: KeychainClient.systemWrite,
        usesSystemAuthorizationHelper: true
    )

    public func read(_ selector: KeychainItemSelector, target: KeychainAuthorizationTarget? = nil,
                     allowUserInteraction: Bool = false) throws -> Data? {
        do {
            let operation = { try snapshotReader(selector, nil, allowUserInteraction)?.data }
            return allowUserInteraction ? try promptGate.perform(operation) : try operation()
        } catch let error as KeychainAccessError {
            if !allowUserInteraction, error.needsUserAuthorization, let target {
                throw KeychainAuthorizationError(target: target, status: error.status)
            }
            throw error
        }
    }

    public func write(_ selector: KeychainItemSelector, data: Data,
                      target: KeychainAuthorizationTarget? = nil) throws {
        do { try writer(selector, data) }
        catch let error as KeychainAccessError {
            if error.needsUserAuthorization, let target {
                throw KeychainAuthorizationError(target: target, status: error.status)
            }
            throw error
        }
    }

    /// One explicit read followed by a normal no-UI read of the exact item.
    /// The failed operation is never replayed and no Keychain value is written.
    public func authorizeAndVerify(_ selector: KeychainItemSelector,
                                   validate: (Data) throws -> String) throws -> KeychainVerificationResult {
        try promptGate.perform {
            guard let first = try snapshotReader(selector, nil, true) else { return .missing }
            guard first.matches(selector) else { return .changed }
            guard let second = try snapshotReader(selector, first.persistentReference, false) else { return .missing }
            guard second.matches(selector), second.persistentReference == first.persistentReference,
                  second.sameItem(as: first) else { return .changed }
            guard let firstIdentity = try? validate(first.data),
                  let secondIdentity = try? validate(second.data) else { return .invalid }
            return firstIdentity == secondIdentity ? .verified : .changed
        }
    }

    public func interactiveSnapshot(_ selector: KeychainItemSelector) throws -> KeychainItemSnapshot? {
        try promptGate.perform { try snapshotReader(selector, nil, true) }
    }

    public func noninteractiveSnapshot(_ selector: KeychainItemSelector,
                                       persistentReference: Data) throws -> KeychainItemSnapshot? {
        try snapshotReader(selector, persistentReference, false)
    }

    static func readQuery(service: String, account: String, allowUserInteraction: Bool = false) -> [String: Any] {
        snapshotQuery(KeychainItemSelector(service: service, account: account), persistentReference: nil,
                      allowUserInteraction: allowUserInteraction)
    }

    static func writeQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authenticationContext(allowUserInteraction: false),
            // Legacy macOS ACL prompts do not consistently honor LAContext's
            // no-UI flag, so the deprecated per-query flag remains required.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
    }

    private static func snapshotQuery(_ selector: KeychainItemSelector, persistentReference: Data?,
                                      allowUserInteraction: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext(allowUserInteraction: allowUserInteraction)
        ]
        if let persistentReference {
            query[kSecValuePersistentRef as String] = persistentReference
        } else {
            query[kSecAttrService as String] = selector.service
            query[kSecAttrAccount as String] = selector.account
            if let accessGroup = selector.accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        }
        if selector.useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        if !allowUserInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return query
    }

    private static func authenticationContext(allowUserInteraction: Bool) -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = !allowUserInteraction
        return context
    }

    private static func systemSnapshot(_ selector: KeychainItemSelector, _ persistentReference: Data?,
                                       _ allowUserInteraction: Bool) throws -> KeychainItemSnapshot? {
        let query = snapshotQuery(selector, persistentReference: persistentReference,
                                  allowUserInteraction: allowUserInteraction)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainAccessError(status: status) }
        guard let values = result as? [String: Any],
              let data = values[kSecValueData as String] as? Data,
              let reference = values[kSecValuePersistentRef as String] as? Data,
              let service = values[kSecAttrService as String] as? String,
              let account = values[kSecAttrAccount as String] as? String else {
            throw KeychainAccessError(status: errSecDecode)
        }
        let actual = KeychainItemSelector(service: service, account: account,
            accessGroup: values[kSecAttrAccessGroup as String] as? String,
            useDataProtectionKeychain: selector.useDataProtectionKeychain)
        return KeychainItemSnapshot(selector: actual, persistentReference: reference, data: data)
    }

    private static func systemWrite(_ selector: KeychainItemSelector, _ data: Data) throws {
        var query = writeQuery(service: selector.service, account: selector.account)
        if let accessGroup = selector.accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        if selector.useDataProtectionKeychain { query[kSecUseDataProtectionKeychain as String] = true }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainAccessError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainAccessError(status: status)
        }
    }
}

private extension KeychainItemSnapshot {
    func matches(_ expected: KeychainItemSelector) -> Bool {
        selector.service == expected.service && selector.account == expected.account
            && (expected.accessGroup == nil || selector.accessGroup == expected.accessGroup)
            && selector.useDataProtectionKeychain == expected.useDataProtectionKeychain
    }
    func sameItem(as other: KeychainItemSnapshot) -> Bool {
        selector.service == other.selector.service && selector.account == other.selector.account
            && selector.accessGroup == other.selector.accessGroup
            && selector.useDataProtectionKeychain == other.selector.useDataProtectionKeychain
    }
}

private struct SystemKeychainStorage: RawVaultStoring {
    let client: KeychainClient
    func read(service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        let selector = KeychainItemSelector(service: service, account: account)
        return try client.read(selector, target: .subscriptionVault, allowUserInteraction: allowUserInteraction)
    }
    func write(service: String, account: String, data: Data, allowUserInteraction: Bool) throws {
        guard !allowUserInteraction else { throw KeychainAccessError(status: errSecInteractionNotAllowed) }
        let selector = KeychainItemSelector(service: service, account: account)
        try client.write(selector, data: data, target: .subscriptionVault)
    }
}

public struct KeychainVault: SecretStoring {
    public static let defaultService = "com.local.subscriptionbar.vault"
    public let service: String
    private let storage: SingleRecordVault
    private let client: KeychainClient
    private var selector: KeychainItemSelector { KeychainItemSelector(service: service, account: SingleRecordVault.account) }

    public init(service: String = KeychainVault.defaultService, root: URL? = nil,
                client: KeychainClient = .system) {
        self.service = service
        self.client = client
        storage = SingleRecordVault(service: service,
            root: root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SubscriptionBar"),
            raw: SystemKeychainStorage(client: client))
    }
    public func read(_ key: String) throws -> Data? { try storage.read(key) }
    public func write(_ key: String, data: Data) throws { try storage.write(key, data: data) }
    public func compareAndSwap(key: String, expected: Data?, data: Data?) throws {
        try storage.compareAndSwap(key: key, expected: expected, data: data)
    }
    public func remove(_ key: String) throws { try storage.remove(key) }
    public func status() -> VaultStatus { storage.status() }
    public func importEntries(_ entries: [String: Data]) throws { try storage.importEntries(entries) }

    public func authorize() throws -> Bool {
        switch try client.authorizeAndVerify(selector, validate: SingleRecordVault.recordIdentity) {
        case .verified: return true
        case .missing: return false
        case .invalid: throw VaultDataError.invalidRecord
        case .changed: throw AppFailure.concurrentChange
        }
    }

    public static func vaultRecordIdentity(_ data: Data) throws -> String {
        try SingleRecordVault.recordIdentity(data)
    }

    public static func disableAutomaticInteraction() throws {
        let status = SecKeychainSetUserInteractionAllowed(false)
        guard status == errSecSuccess else { throw KeychainAccessError(status: status) }
    }

    public static func enableInteractionForAuthorizationHelper() throws {
        let status = SecKeychainSetUserInteractionAllowed(true)
        guard status == errSecSuccess else { throw KeychainAccessError(status: status) }
    }

    public static func read(service: String, account: String, allowUserInteraction: Bool = false,
                            useDataProtectionKeychain: Bool = false,
                            target: KeychainAuthorizationTarget? = nil) throws -> Data? {
        let selector = KeychainItemSelector(service: service, account: account,
                                            useDataProtectionKeychain: useDataProtectionKeychain)
        return try KeychainClient.system.read(selector, target: target,
                                              allowUserInteraction: allowUserInteraction)
    }
    public static func write(service: String, account: String, data: Data,
                             useDataProtectionKeychain: Bool = false,
                             target: KeychainAuthorizationTarget? = nil) throws {
        let selector = KeychainItemSelector(service: service, account: account,
                                            useDataProtectionKeychain: useDataProtectionKeychain)
        try KeychainClient.system.write(selector, data: data, target: target)
    }
    static func readQuery(service: String, account: String, allowUserInteraction: Bool = false) -> [String: Any] {
        KeychainClient.readQuery(service: service, account: account, allowUserInteraction: allowUserInteraction)
    }
    static func writeQuery(service: String, account: String) -> [String: Any] {
        KeychainClient.writeQuery(service: service, account: account)
    }
    public static func claudeServices() throws -> [String] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
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
