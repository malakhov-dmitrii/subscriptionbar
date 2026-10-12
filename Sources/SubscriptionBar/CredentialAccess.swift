import Foundation
import SubscriptionCore

struct CredentialAuthorizationEvent: Equatable {
    let generation: UUID
    let target: KeychainAuthorizationTarget
    let status: Int32

    init(error: KeychainAuthorizationError, generation: UUID = UUID()) {
        self.generation = generation
        target = error.target
        status = error.status
    }
}

enum CredentialAccess: Equatable {
    case checking, ready, authorizationRequired(CredentialAuthorizationEvent)
    case migration(completed: Int, total: Int), invalid, preview

    var permitsPolling: Bool { self == .ready }
    var title: String {
        switch self {
        case .checking: L10n.tr("Checking access")
        case .ready: L10n.tr("Access granted")
        case .authorizationRequired: L10n.tr("Account access required")
        case .migration: L10n.tr("Moving accounts to shared storage")
        case .invalid: L10n.tr("Could not read the vault")
        case .preview: L10n.tr("Viewing saved data")
        }
    }
    var message: String {
        switch self {
        case .checking: L10n.tr("No password prompt.")
        case .ready: ""
        case .authorizationRequired:
            L10n.tr("Monitoring and automatic switching are paused. A system prompt will appear only after you click the button.")
        case .migration(let done, let total):
            L10n.tr("Prepared %@ of %@. Old records will be preserved. Each click requests access at most once.", String(done), String(total))
        case .invalid: L10n.tr("Data has not been overwritten. Automatic recovery is disabled.")
        case .preview:
            L10n.tr("These are real data from the last check. Keychain, network access, and account switching are disabled.")
        }
    }
    var button: String? {
        switch self {
        case .authorizationRequired: L10n.tr("Allow access")
        case .migration(let done, _): done == 0 ? L10n.tr("Move accounts") : L10n.tr("Continue migration")
        default: nil
        }
    }
    func showsBanner(hasAccounts: Bool) -> Bool {
        switch self {
        case .ready: false
        case .authorizationRequired, .invalid: true
        case .migration: true
        case .checking, .preview: hasAccounts
        }
    }
}

struct CredentialRecoveryResolvedError: Error {
    let failure: AppFailure
}

extension AccountRuntime {
    func accessStatus(settings: Settings) -> CredentialAccess {
        switch vault.status() {
        case .missing:
            return settings.accounts.isEmpty ? .ready : migrationProgress(settings)
        case .authorizationRequired(let error):
            return .authorizationRequired(CredentialAuthorizationEvent(error: error))
        case .invalid: return .invalid
        case .ready:
            do {
                for account in settings.accounts {
                    if try vault.read(store.vaultKey(account.id)) == nil { return migrationProgress(settings) }
                }
                for key in try browserKeys(settings) {
                    if try vault.read(key) == nil { return migrationProgress(settings) }
                }
                return .ready
            } catch let error as KeychainAuthorizationError {
                return .authorizationRequired(CredentialAuthorizationEvent(error: error))
            } catch {
                return .invalid
            }
        }
    }

    /// Called only by the explicit button. The exact pending target is preserved
    /// by AppModel until this method proves a normal no-UI read of that item.
    func authorizeAccess(settings: Settings, event: CredentialAuthorizationEvent?) throws -> CredentialAccess {
        if let event {
            if case .claudeCode(let selector) = event.target {
                let current = try CLIConnector(settings: settings, keychain: keychain).claudeKeychainSelector()
                guard selector == current else {
                    throw CredentialRecoveryResolvedError(failure: .concurrentChange)
                }
            }
            let result = try KeychainAuthorizationCommand.authorizeAndVerify(event.target,
                                                                              settings: settings,
                                                                              client: keychain)
            switch (event.target, result) {
            case (_, .verified): return accessStatus(settings: settings)
            case (.subscriptionVault, .missing): return migrationProgress(settings)
            case (.subscriptionVault, .invalid): return .invalid
            case (.subscriptionVault, .changed): throw AppFailure.concurrentChange
            case (.claudeCode(_), .missing): throw CredentialRecoveryResolvedError(failure: .missingCredential)
            case (.claudeCode(_), .invalid): throw CredentialRecoveryResolvedError(failure: .invalidCredential)
            case (.claudeCode(_), .changed): throw CredentialRecoveryResolvedError(failure: .concurrentChange)
            }
        }

        switch vault.status() {
        case .authorizationRequired(let error):
            return .authorizationRequired(CredentialAuthorizationEvent(error: error))
        case .invalid: return .invalid
        case .ready, .missing:
            if case .ready = accessStatus(settings: settings) { return .ready }
            var collection = migration ?? VaultMigration()
            defer { migration = collection }
            let validateExtra: VaultMigration.ExtraValidator = { _, data in
                let cookies = try JSONDecoder().decode([JSONValue].self, from: data)
                guard !cookies.isEmpty, cookies.count < 500 else { throw AppFailure.invalidCredential }
            }
            if collection.totalCount == 0 {
                let extra = try browserKeys(settings)
                var existing: [String: Data] = [:]
                for key in settings.accounts.map({ store.vaultKey($0.id) }) + extra {
                    if let value = try vault.read(key) { existing[key] = value }
                }
                try collection.gatherNonInteractive(settings: settings, extraKeys: extra.sorted(),
                    existingEntries: existing, validateExtra: validateExtra, readLegacy: { key in
                        if let current = try? self.vault.read(key) { return current }
                        return try KeychainVault.read(service: self.vault.service, account: key)
                    }, discoverSources: { ExistingAccountsImporter().discoverReport(settings: settings) })
            }
            if !collection.isComplete {
                try collection.authorizeNext(validateExtra: validateExtra, readLegacyInteractive: { key in
                    try KeychainVault.read(service: self.vault.service, account: key, allowUserInteraction: true)
                })
            }
            guard let entries = collection.completedEntries else {
                return .migration(completed: collection.completedCount, total: collection.totalCount)
            }
            try vault.importEntries(entries)
            for (key, value) in entries {
                guard try vault.read(key) == value else {
                    throw AppFailure.message("Migration was not verified. Old records are preserved.")
                }
            }
            return .ready
        }
    }

    private func migrationProgress(_ settings: Settings) -> CredentialAccess {
        .migration(completed: migration?.completedCount ?? 0, total: migration?.totalCount ?? settings.accounts.count)
    }
    private func browserKeys(_ settings: Settings) throws -> [String] {
        let bridge = BrowserBridge(store: store, vault: vault)
        return try settings.accounts.flatMap { account in
            try bridge.instances(for: account.id).map { bridge.key($0, account.id) }
        }
    }
}
