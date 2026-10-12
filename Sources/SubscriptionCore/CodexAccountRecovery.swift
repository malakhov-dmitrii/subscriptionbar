import Foundation

public struct CodexRecoveryResult: Sendable {
    public let settings: Settings
    public let settingsData: Data
    public let accountID: UUID
    public let reading: UsageSnapshot
}

/// Copies a verified newer native login into its matching saved user/workspace.
/// Never writes to the client, rotates a token or changes the selected account.
public struct CodexAccountRecovery: Sendable {
    private let store: LocalStore
    private let vault: any SecretStoring
    private let capture: @Sendable (Settings) throws -> CredentialEnvelope
    private let fetch: @Sendable (CredentialEnvelope) async throws -> UsageSnapshot

    public init(store: LocalStore, vault: any SecretStoring,
                capture: @escaping @Sendable (Settings) throws -> CredentialEnvelope = { try CLIConnector(settings: $0).capture(.codex) },
                fetch: @escaping @Sendable (CredentialEnvelope) async throws -> UsageSnapshot = {
                    try await UsageAPI().fetch(Self.usageCredential($0))
                }) {
        self.store = store; self.vault = vault; self.capture = capture; self.fetch = fetch
    }

    public func reconcile(settings: Settings, expected: Data?, matchingCurrent: Bool = false) async throws -> CodexRecoveryResult? {
        guard matchingCurrent || settings.enabledProviders.contains(.codex) else { return nil }
        let candidates = settings.accounts.indices.filter {
            settings.accounts[$0].provider == .codex && settings.accounts[$0].canSwitch
                && (matchingCurrent || (settings.accounts[$0].enabled && settings.accounts[$0].id == settings.active[.codex]))
        }
        guard !candidates.isEmpty else { return nil }
        let current = try capture(settings)
        var matches: [(Int, CredentialEnvelope)] = []
        for index in candidates {
            let saved = try store.loadCredential(settings.accounts[index].id, vault: vault)
            if Self.matchesPrincipal(saved, current) {
                matches.append((index, saved))
            }
        }
        guard matches.count <= 1 else { throw AppFailure.invalidCredential }
        guard let (index, saved) = matches.first else { return nil }
        let id = settings.accounts[index].id
        guard Self.matchesPrincipal(saved, current) else { return nil }
        // A settings-first interrupted commit can be resumed using the old vault
        // payload, which still proves the same stable principal as the client.
        guard [saved.identity, current.identity].contains(settings.accounts[index].identity) else {
            throw AppFailure.invalidCredential
        }
        guard current.primary != saved.primary, !Self.isExpired(current), Self.isNewer(current, than: saved) else { return nil }
        for other in settings.accounts where other.provider == .codex && other.id != id {
            let credential = try store.loadCredential(other.id, vault: vault)
            guard !Self.matchesPrincipal(credential, current), other.identity != current.identity else {
                throw AppFailure.invalidCredential
            }
        }
        let reading = try await fetch(current)
        guard reading.isFresh(at: Date()), try capture(settings) == current,
              try store.loadCredential(id, vault: vault) == saved,
              try SecureFiles.read(store.settingsURL) == expected else { throw AppFailure.concurrentChange }
        var updated = settings
        updated.accounts[index].identity = current.identity
        var credential = current
        credential.webSessionKey = saved.webSessionKey
        credential.webOrganizationID = saved.webOrganizationID
        let settingsData = try JSONEncoder().encode(updated)
        let key = store.vaultKey(id)
        guard let before = try vault.read(key),
              try JSONDecoder().decode(CredentialEnvelope.self, from: before) == saved else { throw AppFailure.concurrentChange }
        let after = try JSONEncoder().encode(credential)
        let settingsMutation = Mutation(name: "Codex saved identity", before: expected, after: settingsData,
            read: { try SecureFiles.read(store.settingsURL) }, replace: { data, previous in
                guard let data else { throw AppFailure.invalidCredential }
                // Keep the new binding if credential rollback cannot be proved.
                // New settings + old vault remains recoverable from the old
                // principal; old settings + new vault would lose that evidence.
                if data == expected {
                    guard try vault.read(key) == before else { throw AppFailure.concurrentChange }
                }
                try SecureFiles.write(data, to: store.settingsURL, expected: previous)
            })
        let credentialMutation = Mutation(name: "Codex saved login", before: before, after: after,
            read: { try vault.read(key) }, replace: { data, previous in
                try vault.compareAndSwap(key: key, expected: previous, data: data)
            })
        try CredentialTransaction.perform([settingsMutation, credentialMutation]) {
            guard try capture(settings) == current else { throw AppFailure.concurrentChange }
        }
        return CodexRecoveryResult(settings: updated, settingsData: settingsData, accountID: id, reading: reading)
    }

    public static func isExpired(_ envelope: CredentialEnvelope, now: Date = Date()) -> Bool {
        guard let root = try? JSONValue.parse(envelope.primary),
              let token = root["tokens"]?["access_token"]?.string,
              let expiry = CredentialParser.jwt(token)?["exp"]?.number,
              expiry.isFinite, expiry > 0 else { return false }
        return expiry <= now.timeIntervalSince1970
    }

    public static func usageCredential(_ envelope: CredentialEnvelope) throws -> UsageCredential {
        guard validIdentity(envelope), let root = try? JSONValue.parse(envelope.primary),
              let token = root["tokens"]?["access_token"]?.string,
              let account = root["tokens"]?["account_id"]?.string
                ?? CredentialParser.jwt(root["tokens"]?["id_token"]?.string ?? token)?["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string
        else { throw AppFailure.invalidCredential }
        return UsageCredential(provider: .codex, bearer: token, accountID: account)
    }

    public static func matchesPrincipal(_ lhs: CredentialEnvelope, _ rhs: CredentialEnvelope) -> Bool {
        guard validIdentity(lhs), validIdentity(rhs) else { return false }
        if let left = principal(lhs), let right = principal(rhs) { return left == right }
        return lhs.identity == rhs.identity
    }

    private static func validIdentity(_ envelope: CredentialEnvelope) -> Bool {
        guard let parsed = try? CredentialParser.parse(provider: .codex, data: envelope.primary),
              parsed.identity == envelope.identity,
              let root = try? JSONValue.parse(envelope.primary) else { return false }
        let users = ["id_token", "access_token"].compactMap { key in
            root["tokens"]?[key]?.string.flatMap { CredentialParser.jwt($0)?["https://api.openai.com/auth"]?["chatgpt_user_id"]?.string }
        }
        return !users.contains("") && Set(users).count <= 1
    }

    public static func isNewer(_ incoming: CredentialEnvelope, than saved: CredentialEnvelope) -> Bool {
        func stamp(_ envelope: CredentialEnvelope) -> [Double] {
            guard let root = try? JSONValue.parse(envelope.primary),
                  let token = root["tokens"]?["access_token"]?.string,
                  let claims = CredentialParser.jwt(token) else { return [0, 0, 0] }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let refresh = root["last_refresh"]?.string.flatMap {
                formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }?.timeIntervalSince1970 ?? 0
            return [claims["iat"]?.number ?? 0, refresh, claims["exp"]?.number ?? 0]
        }
        let incomingStamp = stamp(incoming), savedStamp = stamp(saved)
        for (incoming, saved) in zip(incomingStamp, savedStamp) where incoming != saved { return incoming > saved }
        // Legacy subject migration had no timestamp claims. Keep that supported
        // only when neither snapshot can establish a newer token generation.
        return incomingStamp.allSatisfy { $0 == 0 } && incoming.identity != saved.identity
    }

    /// Claims are local continuity evidence; a successful usage request is also
    /// required before committing. Workspace or email alone never establishes it.
    private struct Principal: Equatable { let user: String; let workspace: String }
    private static func principal(_ envelope: CredentialEnvelope) -> Principal? {
        guard let parsed = try? CredentialParser.parse(provider: .codex, data: envelope.primary),
              parsed.identity == envelope.identity,
              let root = try? JSONValue.parse(envelope.primary),
              let idToken = root["tokens"]?["id_token"]?.string,
              let accessToken = root["tokens"]?["access_token"]?.string,
              let id = CredentialParser.jwt(idToken)?["https://api.openai.com/auth"],
              let access = CredentialParser.jwt(accessToken)?["https://api.openai.com/auth"],
              let user = id["chatgpt_user_id"]?.string, !user.isEmpty,
              access["chatgpt_user_id"]?.string == user,
              let workspace = id["chatgpt_account_id"]?.string, !workspace.isEmpty,
              access["chatgpt_account_id"]?.string == workspace else { return nil }
        return Principal(user: user, workspace: workspace)
    }
}
