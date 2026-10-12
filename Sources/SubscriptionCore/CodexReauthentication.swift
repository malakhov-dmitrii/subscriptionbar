import Foundation

public struct CodexReauthenticationPlan: Sendable {
    public let account: Account
    public let workspaceID: String
    public let selectedProfile: CodexClientProfile?
    let settings: Settings
    let expectedSettings: Data?
    let saved: CredentialEnvelope
    let savedBytes: Data
}

public struct CodexReauthenticationValidation: Sendable {
    let plan: CodexReauthenticationPlan
    let candidate: CredentialEnvelope
    let reading: UsageSnapshot
}

/// Accepts an isolated login result for one existing account. Never writes client files.
public struct CodexReauthentication: Sendable {
    private let store: LocalStore
    private let vault: any SecretStoring
    private let fetch: @Sendable (CredentialEnvelope) async throws -> UsageSnapshot

    public init(store: LocalStore, vault: any SecretStoring,
                fetch: @escaping @Sendable (CredentialEnvelope) async throws -> UsageSnapshot) {
        self.store = store; self.vault = vault; self.fetch = fetch
    }

    public func prepare(accountID: UUID, settings: Settings, expected: Data?) throws -> CodexReauthenticationPlan {
        guard let expected, try SecureFiles.read(store.settingsURL) == expected,
              let account = settings.accounts.first(where: { $0.id == accountID }),
              account.provider == .codex, account.canSwitch,
              let bytes = try vault.read(store.vaultKey(accountID)) else { throw AppFailure.concurrentChange }
        let saved = try JSONDecoder().decode(CredentialEnvelope.self, from: bytes)
        guard saved.identity == account.identity, CodexAccountRecovery.matchesPrincipal(saved, saved),
              let workspace = try CodexAccountRecovery.usageCredential(saved).accountID, !workspace.isEmpty else {
            throw AppFailure.invalidCredential
        }
        var all: [UUID: CredentialEnvelope] = [:]
        for other in settings.accounts where other.provider == .codex {
            guard all[other.id] == nil else { throw AppFailure.invalidCredential }
            all[other.id] = try store.loadCredential(other.id, vault: vault)
        }
        guard try CodexCredentialMerge.existingAccount(incoming: saved, accounts: settings.accounts,
                                                       savedCredentials: all)?.id == accountID else {
            throw AppFailure.invalidCredential
        }
        return CodexReauthenticationPlan(account: account, workspaceID: workspace,
            selectedProfile: settings.selectedCodexProfile, settings: settings, expectedSettings: expected,
            saved: saved, savedBytes: bytes)
    }

    public func complete(_ plan: CodexReauthenticationPlan, candidate: CredentialEnvelope) async throws -> CodexRecoveryResult {
        try await commit(validate(plan, candidate: candidate))
    }

    /// Network validation is cancellable and cannot write the saved account or client.
    public func validate(_ plan: CodexReauthenticationPlan, candidate: CredentialEnvelope) async throws -> CodexReauthenticationValidation {
        try Task.checkCancellation()
        try assertCurrent(plan)
        guard CodexAccountRecovery.matchesPrincipal(plan.saved, candidate) else {
            throw AppFailure.message("This sign-in belongs to a different Codex account or workspace. Sign in with the saved account.")
        }
        guard !CodexAccountRecovery.isExpired(candidate) else { throw AppFailure.invalidCredential }
        guard candidate.primary == plan.saved.primary || CodexAccountRecovery.isNewer(candidate, than: plan.saved) else {
            throw AppFailure.message("Codex returned an older saved login. No account was changed. Start sign-in again.")
        }
        let reading = try await fetch(candidate)
        try Task.checkCancellation()
        guard reading.isFresh(at: Date()) else { throw AppFailure.invalidUsage }
        try assertCurrent(plan)
        return CodexReauthenticationValidation(plan: plan, candidate: candidate, reading: reading)
    }

    /// The UI enters a short non-cancellable save phase before invoking this method.
    /// The existing recovery transaction owns subject migration, CAS and guarded rollback.
    public func commit(_ validation: CodexReauthenticationValidation) async throws -> CodexRecoveryResult {
        try Task.checkCancellation()
        let plan = validation.plan, candidate = validation.candidate
        try assertCurrent(plan)
        guard validation.reading.isFresh(at: Date()), !CodexAccountRecovery.isExpired(candidate) else {
            throw AppFailure.invalidUsage
        }
        if candidate.primary == plan.saved.primary {
            guard let data = plan.expectedSettings else { throw AppFailure.concurrentChange }
            return CodexRecoveryResult(settings: plan.settings, settingsData: data,
                                       accountID: plan.account.id, reading: validation.reading)
        }
        let recovery = CodexAccountRecovery(store: store, vault: vault, capture: { _ in candidate }, fetch: { _ in
            try Task.checkCancellation()
            return validation.reading
        })
        guard let result = try await recovery.reconcile(settings: plan.settings, expected: plan.expectedSettings,
                                                        matchingCurrent: true),
              result.accountID == plan.account.id else { throw AppFailure.concurrentChange }
        return result
    }

    private func assertCurrent(_ plan: CodexReauthenticationPlan) throws {
        guard try SecureFiles.read(store.settingsURL) == plan.expectedSettings,
              try vault.read(store.vaultKey(plan.account.id)) == plan.savedBytes else { throw AppFailure.concurrentChange }
    }
}
