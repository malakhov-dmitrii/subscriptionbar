import Foundation

/// A session-local collection step. It never writes, deletes, or commits a vault record.
/// The caller commits completedEntries only after every required item is collected.
public struct VaultMigration: Sendable {
    public typealias LegacyReader = (String) throws -> Data?
    public typealias ExtraValidator = @Sendable (String, Data) throws -> Void
    private var required: [String] = []
    private var accounts: [String: Account] = [:]
    private var active: [Provider: UUID] = [:]
    private var sources: [String: ImportedAccount] = [:]
    private var collected: [String: Data] = [:]
    private var initialized = false

    public init() {}
    public var totalCount: Int { required.count }
    public var completedCount: Int { collected.count }
    public var pendingCount: Int { required.count - collected.count }
    public var isComplete: Bool { initialized && pendingCount == 0 }
    public var completedEntries: [String: Data]? { isComplete ? collected : nil }
    public var nextPendingKey: String? { required.first { collected[$0] == nil } }

    /// Both injected readers must be noninteractive. Original sources are discovered once.
    @discardableResult
    public mutating func gatherNonInteractive(settings: Settings, extraKeys: [String] = [],
                                     existingEntries: [String: Data] = [:],
                                     validateExtra: ExtraValidator = { _, _ in throw AppFailure.invalidCredential },
                                     readLegacy: LegacyReader,
                                     discoverSources: () throws -> ImportReport) throws -> [String: Data]? {
        guard !initialized else { throw AppFailure.message("Migration collection has already started. Continue its pending items.") }
        var keys = Set<String>()
        var ordered: [String] = []
        var accountMap: [String: Account] = [:]
        for account in settings.accounts {
            let key = "account:" + account.id.uuidString
            guard keys.insert(key).inserted else { throw AppFailure.invalidCredential }
            ordered.append(key); accountMap[key] = account
        }
        for key in extraKeys {
            guard !key.isEmpty, !key.hasPrefix("account:"), keys.insert(key).inserted else { throw AppFailure.invalidCredential }
            ordered.append(key)
        }
        guard Set(existingEntries.keys).isSubset(of: keys) else { throw AppFailure.invalidCredential }
        required = ordered; accounts = accountMap
        active = settings.active
        initialized = true
        let report = try discoverSources()
        for (key, account) in accounts {
            let matches = report.accounts.filter { $0.provider == account.provider && $0.credential.identity == account.identity }
            if let source = matches.first(where: { $0.isActive }) ?? matches.first { sources[key] = source }
        }
        for key in required {
            if let existing = existingEntries[key] {
                if let account = accounts[key] {
                    let envelope = try JSONDecoder().decode(CredentialEnvelope.self, from: existing)
                    try validate(envelope, account: account)
                } else { try validateExtra(key, existing) }
                // Already consolidated bytes are authoritative for conflict-protected import.
                // Refreshing them belongs to normal runtime CAS, not this migration.
                collected[key] = existing
                continue
            }
            // Permission denial is represented by nil or a thrown error; neither prompts here.
            let raw: Data?
            do { raw = try readLegacy(key) } catch { raw = nil }
            if let raw { collected[key] = try resolve(key: key, legacy: raw, validateExtra: validateExtra) }
            else if let account = accounts[key], let source = sources[key], sourceCanStandAlone(source, account: account) {
                collected[key] = try resolve(key: key, legacy: nil, validateExtra: validateExtra)
            }
        }
        return completedEntries
    }

    /// Exactly one reader invocation, including cancellation. A later explicit click may retry.
    @discardableResult
    public mutating func authorizeNext(validateExtra: ExtraValidator = { _, _ in throw AppFailure.invalidCredential },
                                      readLegacyInteractive: LegacyReader) throws -> [String: Data]? {
        guard initialized else { throw AppFailure.message("Collect migration sources first.") }
        guard let key = nextPendingKey else { return completedEntries }
        guard let raw = try readLegacyInteractive(key) else { return nil }
        collected[key] = try resolve(key: key, legacy: raw, validateExtra: validateExtra)
        return completedEntries
    }

    private func sourceCanStandAlone(_ source: ImportedAccount, account: Account) -> Bool {
        // Imported Claude entries may pair CLI and web secrets. A CLI-only file cannot
        // establish that no web session would be lost from an inaccessible legacy envelope.
        if account.provider == .claude {
            return source.credential.webSessionKey?.isEmpty == false && source.credential.webOrganizationID?.isEmpty == false
        }
        return true
    }

    private func validate(_ envelope: CredentialEnvelope, account: Account) throws {
        guard envelope.identity == account.identity else { throw AppFailure.invalidCredential }
        if account.monitoringOnly == true, envelope.primary.isEmpty, account.provider == .claude {
            guard let organization = envelope.webOrganizationID, UUID(uuidString: organization) != nil,
                  envelope.identity == "web-org:" + organization,
                  envelope.webSessionKey?.isEmpty == false else { throw AppFailure.invalidCredential }
            return
        }
        let parsed = try CredentialParser.parse(provider: account.provider, data: envelope.primary, metadata: envelope.metadata)
        guard parsed.identity == account.identity else { throw AppFailure.invalidCredential }
    }

    private func resolve(key: String, legacy: Data?, validateExtra: ExtraValidator) throws -> Data {
        guard let account = accounts[key] else {
            guard let legacy else { throw AppFailure.missingCredential }
            try validateExtra(key, legacy)
            return legacy
        }
        var legacyEnvelope: CredentialEnvelope?
        var legacyObject: [String: JSONValue]?
        if let legacy {
            let decoded = try JSONDecoder().decode(CredentialEnvelope.self, from: legacy)
            try validate(decoded, account: account)
            legacyEnvelope = decoded
            legacyObject = try JSONValue.parse(legacy).object
        }
        let source = sources[key]
        let preferSource = source?.isActive == true && active[account.provider] == account.id
        if let legacy, !preferSource { return legacy }
        guard let source else {
            guard let legacy else { throw AppFailure.missingCredential }
            return legacy
        }
        try validate(source.credential, account: account)
        var selected = source.credential
        // Retain the already paired managed web identity. Source discovery must not replace it.
        selected.webSessionKey = legacyEnvelope?.webSessionKey ?? selected.webSessionKey
        selected.webOrganizationID = legacyEnvelope?.webOrganizationID ?? selected.webOrganizationID
        try validate(selected, account: account)
        let encoded = try JSONEncoder().encode(selected)
        guard var original = legacyObject else { return encoded }
        // Preserve future envelope fields when updating only known values from the live source.
        let known = ["primary", "identity", "metadata", "keychainService", "webSessionKey", "webOrganizationID"]
        let selectedObject = try JSONValue.parse(encoded).object ?? [:]
        for field in known { original[field] = selectedObject[field] }
        return try JSONValue.object(original).data()
    }
}
