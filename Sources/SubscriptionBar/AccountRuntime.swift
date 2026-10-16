import Foundation
import SubscriptionCore

struct ForgottenAccountSecrets: Sendable {
    let entries: [String: Data]
}

actor AccountRuntime {
    let store: LocalStore
    let vault: KeychainVault
    let keychain: KeychainClient
    let claudeIdentity: ClaudeIdentityVerifier
    let fetchUsage: @Sendable (UsageCredential) async throws -> UsageSnapshot
    var migration: VaultMigration?

    init(store: LocalStore = LocalStore(), keychain: KeychainClient = .system,
         vault: KeychainVault? = nil,
         claudeIdentity: ClaudeIdentityVerifier = .init(),
         fetchUsage: @escaping @Sendable (UsageCredential) async throws -> UsageSnapshot = { try await UsageAPI().fetch($0) }) {
        self.store = store
        self.keychain = keychain
        self.claudeIdentity = claudeIdentity
        self.vault = vault ?? KeychainVault(root: store.root, client: keychain)
        self.fetchUsage = fetchUsage
    }
    func capture(provider: Provider, settings: Settings, apiKey: String) async throws -> CredentialEnvelope {
        if provider == .cursor {
            let credential = try CursorLocalAuth.read()
            guard let token = String(data: credential.primary, encoding: .utf8) else { throw AppFailure.invalidCredential }
            _ = try await fetchUsage(UsageCredential(provider: .cursor, bearer: token))
            return credential
        }
        if provider.hasCLIProfile {
            let sourceSettings = provider == .codex
                ? try settings.settings(forCodexProfile: CodexClientProfile.selected(in: settings)) : settings
            let connector = CLIConnector(settings: sourceSettings, keychain: keychain)
            let credentials = try connector.capture(provider)
            if provider == .claude {
                let resolved = try await claudeIdentity.resolve(credentials)
                guard try connector.capture(.claude) == credentials else { throw AppFailure.concurrentChange }
                return resolved
            }
            try await verifyIdentity(credentials, provider: provider)
            return credentials
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = try CredentialParser.parse(provider: provider, data: Data(key.utf8))
        if provider == .kimiCode { _ = try await fetchUsage(UsageCredential(provider: provider, bearer: key)) }
        return credential
    }
    func save(account: Account, credential: CredentialEnvelope) throws {
        if account.provider == .codex {
            let key = store.vaultKey(account.id)
            let before = try vault.read(key)
            let saved = try before.map { try JSONDecoder().decode(CredentialEnvelope.self, from: $0) }
            let preferred = try saved.map { try CodexCredentialMerge.preferred(incoming: credential, saved: $0) } ?? credential
            guard preferred.identity == account.identity else { throw AppFailure.concurrentChange }
            try vault.compareAndSwap(key: key, expected: before, data: JSONEncoder().encode(preferred))
            return
        }
        if account.provider == .claude {
            guard credential.identity == account.identity else { throw AppFailure.invalidCredential }
            let key = store.vaultKey(account.id)
            let before = try vault.read(key)
            var updated = credential
            if let before {
                let previous = try JSONDecoder().decode(CredentialEnvelope.self, from: before)
                guard sameClaudePrincipal(previous, credential) else { throw AppFailure.invalidCredential }
                if previous.webOrganizationID == credential.metadata?["organizationUuid"]?.string {
                    updated.webSessionKey = previous.webSessionKey
                    updated.webOrganizationID = previous.webOrganizationID
                }
            }
            try vault.compareAndSwap(key: key, expected: before, data: JSONEncoder().encode(updated))
            return
        }
        try store.saveCredential(account.id, credential: credential, vault: vault)
    }
    func reconcileCodex(settings: Settings, expected: Data?, matchingCurrent: Bool = false) async throws -> CodexRecoveryResult? {
        let profile = try CodexClientProfile.selected(in: settings)
        return try await CodexAccountRecovery(store: store, vault: vault, capture: {
            try CLIConnector(settings: $0.settings(forCodexProfile: profile)).capture(.codex)
        }, fetch: { [fetchUsage] in try await fetchUsage(CodexAccountRecovery.usageCredential($0)) })
            .reconcile(settings: settings, expected: expected, matchingCurrent: matchingCurrent)
    }
    /// Drop the account secret and every saved browser session as one rollback-safe step.
    func forget(_ id: UUID) throws -> ForgottenAccountSecrets {
        let bridge = BrowserBridge(store: store, vault: vault)
        let browserKeys = try bridge.instances(for: id).map { bridge.key($0, id) }
        let keys = Array(Set(browserKeys + [store.vaultKey(id)])).sorted()
        var entries: [String: Data] = [:]
        for key in keys {
            if let data = try vault.read(key) { entries[key] = data }
        }
        var removed: [String] = []
        do {
            for key in keys where entries[key] != nil {
                try vault.remove(key)
                guard try vault.read(key) == nil else {
                    throw AppFailure.message("Account secret cleanup could not be verified.")
                }
                removed.append(key)
            }
        } catch {
            guard restore(entries: entries, keys: removed.reversed()) else {
                throw AppFailure.message("Account secret cleanup failed and its rollback was incomplete.")
            }
            throw error
        }
        return ForgottenAccountSecrets(entries: entries)
    }

    func restore(_ snapshot: ForgottenAccountSecrets) throws {
        guard restore(entries: snapshot.entries, keys: snapshot.entries.keys) else {
            throw AppFailure.message("Account secret cleanup failed and its rollback was incomplete.")
        }
    }

    private func restore<S: Sequence>(entries: [String: Data], keys: S) -> Bool where S.Element == String {
        var restored = true
        for key in keys {
            guard let expected = entries[key] else { continue }
            do {
                if let current = try vault.read(key) {
                    if current != expected { restored = false }
                    continue
                }
                try vault.write(key, data: expected)
                if try vault.read(key) != expected { restored = false }
            } catch { restored = false }
        }
        return restored
    }
    func fetch(account: Account, settings: Settings) async throws -> UsageSnapshot {
        var credentials = try store.loadCredential(account.id, vault: vault)
        if account.provider == .cursor, settings.active[.cursor] == account.id {
            let current = try CursorLocalAuth.read()
            guard current.identity == account.identity else {
                throw AppFailure.message("Cursor is signed into a different account. Connect that account separately.")
            }
            if current != credentials {
                let reading = try await fetchUsage(usageCredential(account: account, envelope: current))
                try store.saveCredential(account.id, credential: current, vault: vault)
                return reading
            }
        }
        if account.provider == .claude, credentials.webSessionKey != nil, credentials.webOrganizationID != nil {
            // Reading web quota must not depend on the unrelated OAuth profile
            // endpoint. The native login is verified separately before a switch.
            return try await fetchUsage(usageCredential(account: account, envelope: credentials))
        }
        if account.provider != .codex && settings.active[account.provider] == account.id && account.canSwitch {
            let connector = CLIConnector(settings: settings, keychain: keychain)
            let source = try connector.capture(account.provider)
            // Claude's local oauthAccount can lag behind the token. An identical
            // previously verified token retains its saved provider-owned identity.
            let current: CredentialEnvelope
            if account.provider == .claude {
                current = source.primary == credentials.primary ? credentials : try await claudeIdentity.resolve(source)
                guard sameClaudePrincipal(current, credentials),
                      try connector.capture(.claude) == source else { throw AppFailure.concurrentChange }
            } else { current = source }
            guard current.identity == account.identity else {
                throw AppFailure.message("The client is signed into a different account. Capture that login before enabling rotation.")
            }
            if current != credentials {
                if account.provider != .claude { try await verifyIdentity(current, provider: account.provider) }
                var updated = current
                updated.webSessionKey = credentials.webSessionKey
                updated.webOrganizationID = credentials.webOrganizationID
                try store.saveCredential(account.id, credential: updated, vault: vault); credentials = updated
            }
        }
        if account.provider == .codex, CodexAccountRecovery.isExpired(credentials) {
            throw AppFailure.message("This saved Codex login has expired. Sign in to that account in Codex, then save it again in SubscriptionBar.")
        }
        let request = try usageCredential(account: account, envelope: credentials)
        return try await fetchUsage(request)
    }
    /// Which saved Claude account the client is using. The token is the
    /// authority because `.claude.json` can lag behind it; the config's
    /// account id decides only when no saved token matches.
    /// ponytail: a token Claude refreshed since our last fetch matches nothing,
    /// so a lagging config wins until the next successful fetch saves it.
    func signedInClaude(settings: Settings) throws -> (account: Account?, login: String)? {
        let connector = CLIConnector(settings: settings, keychain: keychain)
        guard let login = try connector.signedInClaudeAccount() else { return nil }
        let accounts = settings.accounts.filter { $0.provider == .claude }
        if let token = try? connector.capture(.claude).primary {
            let ordered = accounts.sorted { a, _ in a.id == settings.active[.claude] }
            if let owner = ordered.first(where: { (try? store.loadCredential($0.id, vault: vault).primary) == token }) {
                return (owner, login.email ?? login.id)
            }
        }
        return (accounts.first { $0.identity == login.id }, login.email ?? login.id)
    }
    func switchNative(to target: Account, from original: Account, settings: Settings) async throws {
        let connector = CLIConnector(settings: settings, keychain: keychain)
        let source = try connector.capture(target.provider)
        let current = target.provider == .claude ? try await claudeIdentity.resolve(source) : source
        guard current.identity == original.identity else { throw AppFailure.concurrentChange }
        // Preserve the latest refresh-token lineage before changing the active client.
        let previous = try store.loadCredential(original.id, vault: vault)
        if target.provider == .claude {
            guard sameClaudePrincipal(current, previous), try connector.capture(.claude) == source else {
                throw AppFailure.concurrentChange
            }
        }
        var preserved = current
        preserved.webSessionKey = previous.webSessionKey
        preserved.webOrganizationID = previous.webOrganizationID
        try store.saveCredential(original.id, credential: preserved, vault: vault)
        let destination = try store.loadCredential(target.id, vault: vault)
        guard destination.identity == target.identity else { throw AppFailure.invalidCredential }
        try await verifyIdentity(destination, provider: target.provider)
        try connector.apply(destination, provider: target.provider, current: source)
    }
    func browserSwitch(account: Account) async throws {
        let bridge = BrowserBridge(store: store, vault: vault)
        let commands = try bridge.enqueue(account: account)
        try await bridge.awaitResults(commands)
    }
    func hasAnyBrowserSession() -> Bool {
        let connected = (try? BrowserBridge(store: store, vault: vault).connectedInstances()) ?? []
        return !connected.isEmpty
    }
    func hasBrowserSession(_ id: UUID) -> Bool {
        ((try? BrowserBridge(store: store, vault: vault).instances(for: id)) ?? []).isEmpty == false
    }
    func checkBrowserReady(_ id: UUID) throws {
        try BrowserBridge(store: store, vault: vault).requireReady(account: id)
    }
    private func verifyIdentity(_ envelope: CredentialEnvelope, provider: Provider) async throws {
        if provider == .claude {
            guard let metadata = envelope.metadata,
                  let token = try JSONValue.parse(envelope.primary)["claudeAiOauth"]?["accessToken"]?.string else {
                throw AppFailure.invalidCredential
            }
            try await claudeIdentity.verify(token: token, metadata: metadata)
        }
    }
    private func sameClaudePrincipal(_ lhs: CredentialEnvelope, _ rhs: CredentialEnvelope) -> Bool {
        lhs.identity == rhs.identity
            && lhs.metadata?["organizationUuid"]?.string == rhs.metadata?["organizationUuid"]?.string
            && lhs.metadata?["emailAddress"]?.string?.lowercased() == rhs.metadata?["emailAddress"]?.string?.lowercased()
    }
    private func usageCredential(account: Account, envelope: CredentialEnvelope) throws -> UsageCredential {
        guard envelope.identity == account.identity else { throw AppFailure.invalidCredential }
        if account.provider == .claude, let key = envelope.webSessionKey, let org = envelope.webOrganizationID {
            return UsageCredential(provider: .claude, bearer: "", claudeSessionKey: key, claudeOrganizationID: org)
        }
        if !account.provider.hasCLIProfile {
            guard let key = String(data: envelope.primary, encoding: .utf8) else { throw AppFailure.invalidCredential }
            return UsageCredential(provider: account.provider, bearer: key)
        }
        let json = try JSONValue.parse(envelope.primary)
        switch account.provider {
        case .claude:
            guard let token = json["claudeAiOauth"]?["accessToken"]?.string else { throw AppFailure.invalidCredential }
            let cookies = try BrowserBridge(store: store, vault: vault).cookies(account: account.id) ?? []
            let cookie = cookies.first {
                $0["name"]?.string == "sessionKey" && ($0["expirationDate"]?.number ?? .greatestFiniteMagnitude) > Date().timeIntervalSince1970
            }
            let org = envelope.metadata?["organizationUuid"]?.string
            return UsageCredential(provider: .claude, bearer: token, claudeSessionKey: org == nil ? nil : cookie?["value"]?.string,
                                   claudeOrganizationID: org)
        case .codex:
            return try CodexAccountRecovery.usageCredential(envelope)
        case .grok:
            guard let token = CredentialParser.grokRecord(json)?["key"]?.string else { throw AppFailure.invalidCredential }
            return UsageCredential(provider: .grok, bearer: token)
        default: throw AppFailure.invalidCredential
        }
    }
}
