import Foundation
import SubscriptionCore

actor AccountRuntime {
    let store = LocalStore()
    let vault = KeychainVault()
    var migration: VaultMigration?
    func capture(provider: Provider, settings: Settings, apiKey: String) async throws -> CredentialEnvelope {
        if provider == .cursor {
            let credential = try CursorLocalAuth.read()
            guard let token = String(data: credential.primary, encoding: .utf8) else { throw AppFailure.invalidCredential }
            _ = try await UsageAPI().fetch(UsageCredential(provider: .cursor, bearer: token))
            return credential
        }
        if provider.hasCLIProfile {
            let credentials = try CLIConnector(settings: settings).capture(provider)
            try await verifyIdentity(credentials, provider: provider)
            return credentials
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = try CredentialParser.parse(provider: provider, data: Data(key.utf8))
        if provider == .kimiCode { _ = try await UsageAPI().fetch(UsageCredential(provider: provider, bearer: key)) }
        return credential
    }
    func save(account: Account, credential: CredentialEnvelope) throws {
        try store.saveCredential(account.id, credential: credential, vault: vault)
    }
    /// Drop the account secret and every saved browser session for it.
    func forget(_ id: UUID) throws {
        let bridge = BrowserBridge(store: store, vault: vault)
        for instance in (try? bridge.instances(for: id)) ?? [] {
            try? vault.remove(bridge.key(instance, id))
        }
        try vault.remove(store.vaultKey(id))
    }
    func fetch(account: Account, settings: Settings) async throws -> UsageSnapshot {
        var credentials = try store.loadCredential(account.id, vault: vault)
        if account.provider == .cursor, settings.active[.cursor] == account.id {
            let current = try CursorLocalAuth.read()
            guard current.identity == account.identity else {
                throw AppFailure.message("Cursor is signed into a different account. Connect that account separately.")
            }
            if current != credentials {
                let reading = try await UsageAPI().fetch(usageCredential(account: account, envelope: current))
                try store.saveCredential(account.id, credential: current, vault: vault)
                return reading
            }
        }
        if account.provider == .claude, credentials.webSessionKey != nil, credentials.webOrganizationID != nil {
            // Reading web quota must not depend on the unrelated OAuth profile
            // endpoint. The native login is verified separately before a switch.
            return try await UsageAPI().fetch(usageCredential(account: account, envelope: credentials))
        }
        if settings.active[account.provider] == account.id && account.canSwitch {
            let current = try CLIConnector(settings: settings).capture(account.provider)
            guard current.identity == account.identity else {
                throw AppFailure.message("The client is signed into a different account. Capture that login before enabling rotation.")
            }
            if current != credentials {
                try await verifyIdentity(current, provider: account.provider)
                var updated = current
                updated.webSessionKey = credentials.webSessionKey
                updated.webOrganizationID = credentials.webOrganizationID
                try store.saveCredential(account.id, credential: updated, vault: vault); credentials = updated
            }
        }
        let request = try usageCredential(account: account, envelope: credentials)
        return try await UsageAPI().fetch(request)
    }
    func switchNative(to target: Account, from original: Account, settings: Settings) async throws {
        let connector = CLIConnector(settings: settings)
        let current = try connector.capture(target.provider)
        guard current.identity == original.identity else { throw AppFailure.concurrentChange }
        // Preserve the latest refresh-token lineage before changing the active client.
        let previous = try store.loadCredential(original.id, vault: vault)
        var preserved = current
        preserved.webSessionKey = previous.webSessionKey
        preserved.webOrganizationID = previous.webOrganizationID
        try store.saveCredential(original.id, credential: preserved, vault: vault)
        let destination = try store.loadCredential(target.id, vault: vault)
        guard destination.identity == target.identity else { throw AppFailure.invalidCredential }
        try await verifyIdentity(destination, provider: target.provider)
        try connector.apply(destination, provider: target.provider, current: current)
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
            try await ClaudeIdentityVerifier().verify(token: token, metadata: metadata)
        }
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
            guard let token = json["tokens"]?["access_token"]?.string else { throw AppFailure.invalidCredential }
            return UsageCredential(provider: .codex, bearer: token, accountID: json["tokens"]?["account_id"]?.string)
        case .grok:
            guard let token = CredentialParser.grokRecord(json)?["key"]?.string else { throw AppFailure.invalidCredential }
            return UsageCredential(provider: .grok, bearer: token)
        default: throw AppFailure.invalidCredential
        }
    }
}
