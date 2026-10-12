import Foundation
import SubscriptionCore

struct CodexSwitchPlan: Sendable {
    let profile: CodexClientProfile
    let target: Account
    let destination: CredentialEnvelope
    let before: Data?
    let settings: Settings
    let expectedSettings: Data?
    let reading: UsageSnapshot
}

struct CodexSwitchResult: Sendable {
    let settings: Settings
    let settingsData: Data
}

struct CodexCaptureResult: Sendable {
    let commit: CodexCredentialCommitResult
    let keptNewer: Bool
}

extension AccountRuntime {
    func saveCodexCapture(label: String, settings: Settings, expected: Data?) async throws -> CodexCaptureResult {
        let profile = try CodexClientProfile.selected(in: settings)
        let connector = CLIConnector(settings: settings.settings(forCodexProfile: profile))
        let captured = try connector.capture(.codex)
        guard !CodexAccountRecovery.isExpired(captured) else {
            throw AppFailure.message("This saved Codex login has expired. Sign in to that account in Codex, then save it again in SubscriptionBar.")
        }
        let reading = try await fetchUsage(CodexAccountRecovery.usageCredential(captured))
        guard reading.isFresh(at: Date()), try connector.capture(.codex) == captured,
              try SecureFiles.read(store.settingsURL) == expected else { throw AppFailure.concurrentChange }
        let result = try CodexCredentialMerge.commit(incoming: captured, label: label, makeActive: true,
            settings: settings, expected: expected, store: store, vault: vault)
        return CodexCaptureResult(commit: result, keptNewer: result.credential.primary != captured.primary)
    }

    func synchronizeCodex(settings: Settings, expected: Data?) async throws -> CodexSynchronizationResult {
        try await CodexProfileSynchronizer(store: store, vault: vault,
            fetch: { [fetchUsage] in try await fetchUsage(CodexAccountRecovery.usageCredential($0)) })
            .synchronize(settings: settings, expected: expected)
    }

    func prepareCodexSwitch(to target: Account, settings: Settings, expected: Data?) async throws -> CodexSwitchPlan {
        let profile = try CodexClientProfile.selected(in: settings)
        guard target.provider == .codex, target.enabled, target.canSwitch,
              settings.accounts.contains(target), try SecureFiles.read(store.settingsURL) == expected else {
            throw AppFailure.concurrentChange
        }
        let destination = try store.loadCredential(target.id, vault: vault)
        guard destination.identity == target.identity else { throw AppFailure.invalidCredential }
        let current = try codexSource(profile: profile, settings: settings)
        if let current {
            let matches = try settings.accounts.filter { account in
                guard account.provider == .codex else { return false }
                return CodexAccountRecovery.matchesPrincipal(try store.loadCredential(account.id, vault: vault), current)
            }
            guard matches.count == 1, let original = matches.first,
                  original.id == settings.active[.codex],
                  try CodexCredentialMerge.preferred(incoming: current,
                      saved: store.loadCredential(original.id, vault: vault)).primary == store.loadCredential(original.id, vault: vault).primary else {
                throw AppFailure.message("Save or refresh the selected profile's current login before switching.")
            }
        } else if settings.active[.codex] != nil { throw AppFailure.concurrentChange }
        // A native refresh token must not be copied into a second running profile.
        for other in try CodexClientProfile.validate(settings.effectiveCodexProfiles) where other.id != profile.id {
            if let source = try codexSource(profile: other, settings: settings),
               CodexAccountRecovery.matchesPrincipal(source, destination) {
                throw AppFailure.message("This account is already used by another Codex profile. Select that profile instead.")
            }
        }
        let reading = try await fetch(account: target, settings: settings)
        guard reading.isFresh(at: Date()), !RotationPolicy.exhausted(reading, account: target),
              try codexSource(profile: profile, settings: settings)?.primary == current?.primary,
              try store.loadCredential(target.id, vault: vault) == destination,
              try SecureFiles.read(store.settingsURL) == expected else { throw AppFailure.concurrentChange }
        return CodexSwitchPlan(profile: profile, target: target, destination: destination,
                               before: current?.primary, settings: settings, expectedSettings: expected, reading: reading)
    }

    /// Caller closes only the preflighted native instance before entering this synchronous commit.
    func commitCodexSwitch(_ plan: CodexSwitchPlan) throws -> CodexSwitchResult {
        guard plan.reading.isFresh(at: Date()),
              try CodexClientProfile.selected(in: plan.settings) == plan.profile,
              try SecureFiles.read(store.settingsURL) == plan.expectedSettings,
              try store.loadCredential(plan.target.id, vault: vault) == plan.destination,
              try codexSource(profile: plan.profile, settings: plan.settings)?.primary == plan.before else {
            throw AppFailure.concurrentChange
        }
        for other in try CodexClientProfile.validate(plan.settings.effectiveCodexProfiles) where other.id != plan.profile.id {
            if let source = try codexSource(profile: other, settings: plan.settings),
               CodexAccountRecovery.matchesPrincipal(source, plan.destination) { throw AppFailure.concurrentChange }
        }
        var updated = plan.settings
        updated.active[.codex] = plan.target.id
        updated.lastSwitch[.codex] = Date()
        let afterSettings = try JSONEncoder().encode(updated)
        let authURL = URL(fileURLWithPath: plan.profile.home).appendingPathComponent("auth.json")
        let auth = try Mutation.file(authURL, after: plan.destination.primary)
        guard auth.before == plan.before else { throw AppFailure.concurrentChange }
        let store = self.store
        let settingsMutation = Mutation(name: "Codex selected account", before: plan.expectedSettings, after: afterSettings,
            read: { try SecureFiles.read(store.settingsURL) }, replace: { value, expected in
                guard let value else { throw AppFailure.invalidCredential }
                try SecureFiles.write(value, to: store.settingsURL, expected: expected)
            })
        try CredentialTransaction.perform([auth, settingsMutation]) {
            guard try codexSource(profile: plan.profile, settings: updated)?.primary == plan.destination.primary else {
                throw AppFailure.concurrentChange
            }
        }
        return CodexSwitchResult(settings: updated, settingsData: afterSettings)
    }

    private func codexSource(profile: CodexClientProfile, settings: Settings) throws -> CredentialEnvelope? {
        do { return try CLIConnector(settings: settings.settings(forCodexProfile: profile)).capture(.codex) }
        catch AppFailure.missingCredential { return nil }
    }
}
