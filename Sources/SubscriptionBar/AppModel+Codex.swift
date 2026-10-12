import Foundation
import SubscriptionCore

extension AppModel {
    var codexAccountsOwnedElsewhere: Set<UUID> {
        Set(codexObservations.values.filter { $0.profileID != settings.selectedCodexProfile?.id }.compactMap(\.accountID))
    }
    var codexRotationReady: Bool {
        guard let profile = settings.selectedCodexProfile, let observation = codexObservations[profile.id] else { return false }
        return observation.issue == nil && observation.accountID != nil && observation.accountID == settings.active[.codex]
    }

    var codexProfileIssue: String? {
        guard let profile = settings.selectedCodexProfile else {
            return t("Select a Codex profile to switch accounts. Saved accounts are still monitored.")
        }
        return codexObservations[profile.id]?.issue
    }

    func reloadCodexSettings() {
        if let data = try? SecureFiles.read(store.settingsURL),
           let latest = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = latest; settingsData = data
        }
    }

    func saveCodexProfiles(_ profiles: [CodexClientProfile], selected: UUID?) throws {
        guard !busy, !previewOnly else { throw AppFailure.concurrentChange }
        let profiles = try CodexClientProfile.validate(profiles)
        guard profiles.isEmpty ? selected == nil : profiles.contains(where: { $0.id == selected }) else {
            throw CodexProfileValidationError.invalidSelection
        }
        var updated = settings
        updated.codexClientProfiles = profiles
        updated.selectedCodexClientID = selected
        updated.active[.codex] = nil
        let data = demo ? settingsData : try store.saveSettings(updated, expected: settingsData)
        settings = updated; settingsData = data; codexObservations = [:]
    }

    func selectCodexProfile(_ id: UUID) {
        guard !busy, !previewOnly else { return }
        do {
            let profiles = try CodexClientProfile.validate(settings.effectiveCodexProfiles)
            guard profiles.contains(where: { $0.id == id }) else { throw CodexProfileValidationError.invalidSelection }
            var updated = settings
            updated.selectedCodexClientID = id
            updated.active[.codex] = codexObservations[id]?.issue == nil ? codexObservations[id]?.accountID : nil
            let data = demo ? settingsData : try store.saveSettings(updated, expected: settingsData)
            settings = updated; settingsData = data
        } catch { recordOperationFailure(error) }
    }

    func synchronizeCodexProfiles() async {
        guard settings.enabledProviders.contains(.codex) else { return }
        do {
            let result = try await runtime.synchronizeCodex(settings: settings, expected: settingsData)
            settings = result.settings; settingsData = result.settingsData
            codexObservations = result.observations
            for (id, reading) in result.readings { publishReading(reading, for: id) }
            let observed = settings.selectedCodexProfile.flatMap { result.observations[$0.id] }
            let active = observed?.issue == nil ? observed?.accountID : nil
            if settings.active[.codex] != active {
                settings.active[.codex] = active
                try saveOrThrow()
            }
        } catch {
            reloadCodexSettings()
            codexObservations = [:]
            for profile in settings.effectiveCodexProfiles {
                codexObservations[profile.id] = CodexProfileObservation(profileID: profile.id, accountID: nil, issue: errorText(error))
            }
            recordOperationFailure(error)
        }
    }

    func reconcileCodex(matchingCurrent: Bool = false) async throws {
        do {
            if let result = try await runtime.reconcileCodex(settings: settings, expected: settingsData, matchingCurrent: matchingCurrent) {
                settings = result.settings; settingsData = result.settingsData
                publishReading(result.reading, for: result.accountID)
            }
        } catch { reloadCodexSettings(); throw error }
    }

    func addCodexAccount(label: String) async throws -> Bool {
        try await reconcileCodex(matchingCurrent: true)
        let wasOff = !settings.enabledProviders.contains(.codex)
        do {
            let result = try await runtime.saveCodexCapture(label: label, settings: settings, expected: settingsData)
            settings = result.commit.settings; settingsData = result.commit.settingsData
            let account = result.commit.account
            var message = result.commit.isNew ? t("Added %@: %@.", Provider.codex.name, account.label)
                : result.keptNewer ? t("Kept the newer saved login for %@.", account.label) : t("Sign-in updated: %@.", account.label)
            if result.commit.isNew && wasOff { message += " " + t("%@ was switched back on in Settings.", Provider.codex.name) }
            setResult(message)
            return true
        } catch { reloadCodexSettings(); throw error }
    }

    @discardableResult
    func performCodexSwitch(_ target: Account, automatic: Bool = false, reinstallCurrent: Bool = false) async -> Bool {
        if demo {
            settings.active[.codex] = target.id
            setResult(t("Demo: selected %@. Real sign-ins were not changed.", target.label))
            return true
        }
        var receipt: CodexRestartReceipt?
        do {
            guard settings.restartCodex else { throw AppFailure.message(t("Allow restarting Codex in Settings to switch accounts.")) }
            let requestedProfile = settings.selectedCodexProfile
            await synchronizeCodexProfiles()
            guard credentialAccess.permitsPolling else { return false }
            guard settings.selectedCodexProfile == requestedProfile else { throw AppFailure.concurrentChange }
            if automatic {
                guard codexRotationReady else { return false }
                let decision = RotationPolicy.decide(provider: .codex, settings: settings, readings: readings,
                    failures: Set(errors.keys).union(codexAccountsOwnedElsewhere))
                guard case .switchTo(let id) = decision, id == target.id else { return false }
            }
            if settings.active[.codex] == target.id && !reinstallCurrent { return true }
            let targetID = target.id
            guard let target = settings.accounts.first(where: { $0.id == targetID }) else { throw AppFailure.concurrentChange }
            settings.automationPausedReason = t("Switching did not finish. Check the active account before continuing.")
            try saveOrThrow()
            let plan = try await runtime.prepareCodexSwitch(to: target, settings: settings, expected: settingsData)
            let switchBrowser = target.browserEnabled && settings.effectiveCodexProfiles.count == 1
            if switchBrowser { try await runtime.checkBrowserReady(target.id) }
            receipt = try await DesktopHandoff.closeCodex(profile: plan.profile)
            guard let closed = receipt else { throw AppFailure.concurrentChange }
            try DesktopHandoff.validateCodexClosed(closed)
            let result = try await runtime.commitCodexSwitch(plan)
            settings = result.settings; settingsData = result.settingsData
            try DesktopHandoff.validateCodexClosed(closed)
            try await DesktopHandoff.reopen(closed)
            receipt = nil
            publishReading(plan.reading, for: target.id)
            codexObservations[plan.profile.id] = CodexProfileObservation(profileID: plan.profile.id, accountID: target.id)
            if switchBrowser { try await runtime.browserSwitch(account: target) }
            settings.automationPausedReason = nil
            try saveOrThrow()
            setResult(t("%@ → %@. Credentials verified.", plan.profile.name, target.label)
                + "\n" + t(" Codex was reopened if it was running. Task resumption is unverified."))
            try store.saveReceipt(lastResult)
            notify(.codex, message: lastResult)
            return true
        } catch {
            if let partial = error as? CodexHandoffFailure { receipt = partial.receipt }
            if let receipt { try? await DesktopHandoff.reopen(receipt) }
            reloadCodexSettings()
            settings.automationPausedReason = t("Automatic switching paused after an error.")
            recordOperationFailure(error)
            try? saveOrThrow(); try? store.saveReceipt(lastResult)
            notify(.codex, message: lastResult)
            return false
        }
    }
}
