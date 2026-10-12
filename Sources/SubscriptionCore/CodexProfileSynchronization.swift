import Foundation

public struct CodexProfileObservation: Sendable, Equatable {
    public let profileID: UUID
    public let accountID: UUID?
    public let issue: String?

    public init(profileID: UUID, accountID: UUID?, issue: String? = nil) {
        self.profileID = profileID; self.accountID = accountID; self.issue = issue
    }
}

public struct CodexSynchronizationResult: Sendable {
    public let settings: Settings
    public let settingsData: Data?
    public let readings: [UUID: UsageSnapshot]
    public let observations: [UUID: CodexProfileObservation]
}

/// Observes clients independently and reconciles saved credentials without selecting an account.
public struct CodexProfileSynchronizer: Sendable {
    private let store: LocalStore
    private let vault: any SecretStoring
    private let capture: @Sendable (CodexClientProfile, Settings) throws -> CredentialEnvelope
    private let fetch: @Sendable (CredentialEnvelope) async throws -> UsageSnapshot

    public init(store: LocalStore, vault: any SecretStoring,
                capture: @escaping @Sendable (CodexClientProfile, Settings) throws -> CredentialEnvelope = { profile, settings in
                    try CLIConnector(settings: settings.settings(forCodexProfile: profile)).capture(.codex)
                }, fetch: @escaping @Sendable (CredentialEnvelope) async throws -> UsageSnapshot = {
                    try await UsageAPI().fetch(CodexAccountRecovery.usageCredential($0))
                }) {
        self.store = store; self.vault = vault; self.capture = capture; self.fetch = fetch
    }

    public func synchronize(settings: Settings, expected: Data?) async throws -> CodexSynchronizationResult {
        let profiles = try CodexClientProfile.validate(settings.effectiveCodexProfiles)
        var current = settings
        var settingsData = expected
        var readings: [UUID: UsageSnapshot] = [:]
        var observations: [UUID: CodexProfileObservation] = [:]
        guard try SecureFiles.read(store.settingsURL) == expected else {
            return try changedSettingsResult(profiles: profiles)
        }
        // An unreadable saved vault is a global failure, not evidence that a client signed out.
        var saved = try credentials(current)
        var writesStopped = false
        for profile in profiles {
            let source: CredentialEnvelope
            do { source = try capture(profile, current) }
            catch {
                observations[profile.id] = observation(profile, issue: error)
                continue
            }
            let matches = current.accounts.filter { account in
                guard account.provider == .codex, account.canSwitch, let credential = saved[account.id] else { return false }
                return CodexAccountRecovery.matchesPrincipal(credential, source)
            }
            guard matches.count == 1, let account = matches.first else {
                let issue = matches.isEmpty ? L10n.tr("The current Codex login is not a saved account.")
                    : AppFailure.invalidCredential.localizedDescription
                observations[profile.id] = CodexProfileObservation(profileID: profile.id, accountID: nil, issue: issue)
                continue
            }
            guard !writesStopped else {
                observations[profile.id] = observation(profile, issue: AppFailure.concurrentChange)
                continue
            }
            do {
                let recovery = CodexAccountRecovery(store: store, vault: vault, capture: { settings in
                    let reread = try capture(profile, settings)
                    guard reread == source else { throw AppFailure.concurrentChange }
                    return reread
                }, fetch: fetch)
                if let result = try await recovery.reconcile(settings: current, expected: settingsData, matchingCurrent: true) {
                    guard result.accountID == account.id else { throw AppFailure.concurrentChange }
                    current = result.settings
                    settingsData = result.settingsData
                    readings[result.accountID] = result.reading
                    saved = try credentials(current)
                }
                guard try capture(profile, current) == source,
                      try SecureFiles.read(store.settingsURL) == settingsData,
                      try credentials(current) == saved else { throw AppFailure.concurrentChange }
                observations[profile.id] = CodexProfileObservation(profileID: profile.id, accountID: account.id)
            } catch {
                let observedAccount = (error as? AppFailure) == .concurrentChange ? nil : account.id
                observations[profile.id] = observation(profile, accountID: observedAccount, issue: error)
                // A failed transaction may already have committed its settings half.
                // Never carry the caller's old CAS bytes into another profile's write.
                let actual = try SecureFiles.read(store.settingsURL)
                if actual != settingsData { return try changedSettingsResult(profiles: profiles) }
                let actualSaved = try credentials(current)
                if actualSaved != saved {
                    saved = actualSaved
                    writesStopped = true
                    readings.removeAll()
                    for observed in profiles where observations[observed.id] != nil {
                        observations[observed.id] = observation(observed, issue: AppFailure.concurrentChange)
                    }
                }
            }
        }
        guard try SecureFiles.read(store.settingsURL) == settingsData else {
            return try changedSettingsResult(profiles: profiles)
        }
        return CodexSynchronizationResult(settings: current, settingsData: settingsData,
                                          readings: readings, observations: observations)
    }

    private func credentials(_ settings: Settings) throws -> [UUID: CredentialEnvelope] {
        var result: [UUID: CredentialEnvelope] = [:]
        for account in settings.accounts where account.provider == .codex && account.canSwitch {
            guard result[account.id] == nil else { throw AppFailure.invalidCredential }
            result[account.id] = try store.loadCredential(account.id, vault: vault)
        }
        return result
    }

    private func changedSettingsResult(profiles: [CodexClientProfile]) throws -> CodexSynchronizationResult {
        let data = try SecureFiles.read(store.settingsURL)
        guard let data else { throw AppFailure.concurrentChange }
        let settings = try JSONDecoder().decode(Settings.self, from: data)
        let observations = Dictionary(uniqueKeysWithValues: profiles.map {
            ($0.id, observation($0, issue: AppFailure.concurrentChange))
        })
        return CodexSynchronizationResult(settings: settings, settingsData: data, readings: [:], observations: observations)
    }

    private func observation(_ profile: CodexClientProfile, accountID: UUID? = nil, issue: Error) -> CodexProfileObservation {
        let message: String
        if issue is AppFailure || issue is KeychainAccessError || issue is KeychainAuthorizationError {
            message = issue.localizedDescription
        } else {
            // Provider or decoder errors can embed request data; keep it out of UI status.
            message = AppFailure.invalidCredential.localizedDescription
        }
        return CodexProfileObservation(profileID: profile.id, accountID: accountID, issue: message)
    }
}
