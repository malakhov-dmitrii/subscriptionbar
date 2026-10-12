import Foundation

public struct CodexCredentialCommitResult: Sendable {
    public let settings: Settings
    public let settingsData: Data
    public let account: Account
    public let credential: CredentialEnvelope
    public let isNew: Bool
}

/// Resolves imported/native snapshots without replacing a newer saved login.
public enum CodexCredentialMerge {
    public static func preferred(incoming: CredentialEnvelope, saved: CredentialEnvelope) throws -> CredentialEnvelope {
        guard CodexAccountRecovery.matchesPrincipal(incoming, saved) else { throw AppFailure.invalidCredential }
        guard incoming.primary != saved.primary,
              !CodexAccountRecovery.isExpired(incoming),
              CodexAccountRecovery.isNewer(incoming, than: saved) else { return saved }
        var result = incoming
        result.webSessionKey = saved.webSessionKey
        result.webOrganizationID = saved.webOrganizationID
        return result
    }

    /// All saved Codex credentials must be supplied so a sub alias cannot create a duplicate account.
    public static func existingAccount(incoming: CredentialEnvelope, accounts: [Account],
                                       savedCredentials: [UUID: CredentialEnvelope]) throws -> Account? {
        guard CodexAccountRecovery.matchesPrincipal(incoming, incoming) else { throw AppFailure.invalidCredential }
        var matches: [Account] = []
        var ids = Set<UUID>()
        for account in accounts where account.provider == .codex {
            guard ids.insert(account.id).inserted,
                  let saved = savedCredentials[account.id],
                  account.identity == saved.identity,
                  CodexAccountRecovery.matchesPrincipal(saved, saved) else { throw AppFailure.invalidCredential }
            let samePrincipal = CodexAccountRecovery.matchesPrincipal(incoming, saved)
            if account.identity == incoming.identity && !samePrincipal { throw AppFailure.invalidCredential }
            if samePrincipal { matches.append(account) }
        }
        guard matches.count <= 1 else { throw AppFailure.invalidCredential }
        return matches.first
    }

    public static func commit(incoming: CredentialEnvelope, label: String, makeActive: Bool,
                              settings: Settings, expected: Data?, store: LocalStore,
                              vault: any SecretStoring) throws -> CodexCredentialCommitResult {
        guard try SecureFiles.read(store.settingsURL) == expected else { throw AppFailure.concurrentChange }
        var saved: [UUID: CredentialEnvelope] = [:]
        var savedBytes: [UUID: Data] = [:]
        for account in settings.accounts where account.provider == .codex {
            guard saved[account.id] == nil, let data = try vault.read(store.vaultKey(account.id)) else {
                throw AppFailure.invalidCredential
            }
            savedBytes[account.id] = data
            saved[account.id] = try JSONDecoder().decode(CredentialEnvelope.self, from: data)
        }
        let existing = try existingAccount(incoming: incoming, accounts: settings.accounts, savedCredentials: saved)
        let account = existing ?? Account(provider: .codex, label: label, identity: incoming.identity)
        let credential = try saved[account.id].map { try preferred(incoming: incoming, saved: $0) } ?? incoming
        // Subject migration belongs to recovery, which first proves provider access.
        guard credential.identity == account.identity else { throw AppFailure.concurrentChange }
        var updated = settings
        if existing == nil {
            updated.accounts.append(account)
            updated.enabledProviders.insert(.codex)
        }
        if makeActive { updated.active[.codex] = account.id }
        let afterSettings = try JSONEncoder().encode(updated)
        let key = store.vaultKey(account.id)
        let beforeCredential = savedBytes[account.id]
        let afterCredential = try JSONEncoder().encode(credential)
        let settingsMutation = Mutation(name: "Saved Codex account", before: expected, after: afterSettings,
            read: { try SecureFiles.read(store.settingsURL) }, replace: { data, previous in
                if data == expected {
                    guard try vault.read(key) == beforeCredential else { throw AppFailure.concurrentChange }
                }
                if let data { try SecureFiles.write(data, to: store.settingsURL, expected: previous) }
                else if let previous { try SecureFiles.remove(store.settingsURL, expected: previous) }
            })
        let credentialMutation = Mutation(name: "Saved Codex login", before: beforeCredential, after: afterCredential,
            read: { try vault.read(key) }, replace: { data, previous in
                try vault.compareAndSwap(key: key, expected: previous, data: data)
            })
        try CredentialTransaction.perform([settingsMutation, credentialMutation]) {
            guard try SecureFiles.read(store.settingsURL) == afterSettings,
                  try vault.read(key) == afterCredential else { throw AppFailure.concurrentChange }
        }
        return CodexCredentialCommitResult(settings: updated, settingsData: afterSettings, account: account,
                                            credential: credential, isNew: existing == nil)
    }
}
