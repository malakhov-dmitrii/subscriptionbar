import Foundation
import SubscriptionCore

enum CredentialAccess: Equatable {
    case checking, ready, locked, migration(completed: Int, total: Int), invalid, preview
    var permitsPolling: Bool { self == .ready }
    var title: String {
        switch self {
        case .checking: L10n.tr("Checking access")
        case .ready: L10n.tr("Access granted")
        case .locked: L10n.tr("Account access required")
        case .migration: L10n.tr("Moving accounts to shared storage")
        case .invalid: L10n.tr("Could not read the vault")
        case .preview: L10n.tr("Viewing saved data")
        }
    }
    var message: String {
        switch self {
        case .checking: L10n.tr("No password prompt.")
        case .ready: ""
        case .locked: L10n.tr("Monitoring and automatic switching are paused. A system prompt will appear only after you click the button.")
        case .migration(let done, let total): L10n.tr("Prepared %@ of %@. Old records will be preserved. Each click requests access at most once.", String(done), String(total))
        case .invalid: L10n.tr("Data has not been overwritten. Automatic recovery is disabled.")
        case .preview: L10n.tr("These are real data from the last check. Keychain, network access, and account switching are disabled.")
        }
    }
    var button: String? {
        switch self {
        case .locked: L10n.tr("Allow access")
        case .migration(let done, _): done == 0 ? L10n.tr("Move accounts") : L10n.tr("Continue migration")
        default: nil
        }
    }
}

extension AccountRuntime {
    func accessStatus(settings: Settings) -> CredentialAccess {
        switch vault.status() {
        case .missing:
            return settings.accounts.isEmpty ? .ready : migrationProgress(settings)
        case .locked: return .locked
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
            } catch { return .locked }
        }
    }
    /// Called only by the explicit button, never by a poll or a retry loop.
    func authorizeAccess(settings: Settings) throws -> CredentialAccess {
        switch vault.status() {
        case .locked:
            guard try vault.authorize() else { return migrationProgress(settings) }
            if let entries = migration?.completedEntries { try vault.importEntries(entries) }
            return accessStatus(settings: settings)
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
            // Read-back each value through the noninteractive single record API.
            for (key, value) in entries {
                guard try vault.read(key) == value else { throw AppFailure.message("Migration was not verified. Old records are preserved.") }
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
