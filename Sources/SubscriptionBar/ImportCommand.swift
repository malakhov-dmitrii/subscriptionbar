import Foundation
import SubscriptionCore

enum ImportCommand {
    static func run(importAccounts: Bool, enableAutomation: Bool = false) async {
        let store = LocalStore(), vault = KeychainVault(), runtime = AccountRuntime()
        do {
            var expected = try SecureFiles.read(store.settingsURL)
            var settings = try store.loadSettings()
            if importAccounts {
                // Persist the migration pause before saving any account. No live client
                // is switched by discovery, import, or this read-only quota check.
                settings.automationPausedReason = "Импортированы реальные аккаунты. Проверяем лимиты перед включением автосмены."
                expected = try store.saveSettings(settings, expected: expected)
                var report = ExistingAccountsImporter().discoverReport(settings: settings)
                // A matching organization alone is not a matching user. Bind the
                // Tracker session only after its server confirms the CLI user's
                // email AND membership in that exact organization.
                var linkedWebIdentities: Set<String> = []
                for index in report.accounts.indices where report.accounts[index].provider == .claude && !report.accounts[index].monitoringOnly {
                    guard let metadata = report.accounts[index].credential.metadata else { continue }
                    for web in report.accounts where web.provider == .claude && web.monitoringOnly {
                        guard let key = web.credential.webSessionKey,
                              web.credential.webOrganizationID == metadata["organizationUuid"]?.string else { continue }
                        do {
                            try await ClaudeIdentityVerifier().verifyWeb(sessionKey: key, metadata: metadata)
                            report.accounts[index].credential.webSessionKey = key
                            report.accounts[index].credential.webOrganizationID = web.credential.webOrganizationID
                            report.accounts[index].label = web.label
                            linkedWebIdentities.insert(web.credential.identity)
                            print("LINKED Claude web session: server email and organization match current CLI metadata.")
                        } catch { print("LINK_UNVERIFIED Claude web/CLI pairing kept separate.") }
                    }
                }
                report.accounts.removeAll { linkedWebIdentities.contains($0.credential.identity) }
                if !linkedWebIdentities.isEmpty && !report.accounts.contains(where: { $0.provider == .claude && $0.monitoringOnly }) {
                    report.warnings.removeAll { $0.contains("web usage monitoring only") }
                }
                // Remove an earlier imported monitor-only duplicate only after the
                // server-verified pairing above. Original trackers stay untouched.
                settings.accounts.removeAll { $0.monitoringOnly == true && linkedWebIdentities.contains($0.identity) }
                for item in report.accounts {
                    var account = settings.accounts.first { $0.provider == item.provider && $0.identity == item.credential.identity }
                        ?? Account(provider: item.provider, label: item.label, identity: item.credential.identity)
                    account.monitoringOnly = item.monitoringOnly
                    try store.saveCredential(account.id, credential: item.credential, vault: vault)
                    guard try store.loadCredential(account.id, vault: vault) == item.credential else { throw AppFailure.invalidCredential }
                    if let index = settings.accounts.firstIndex(where: { $0.id == account.id }) { settings.accounts[index] = account }
                    else { settings.accounts.append(account) }
                    if item.isActive || settings.active[item.provider] == nil { settings.active[item.provider] = account.id }
                    settings.enabledProviders.insert(item.provider)
                }
                expected = try store.saveSettings(settings, expected: expected)
                for provider in Provider.allCases {
                    let count = settings.accounts.filter { $0.provider == provider }.count
                    if count > 0 { print("IMPORTED \(provider.rawValue): \(count) account(s)") }
                }
                for warning in report.warnings { print("IMPORT_WARNING \(warning)") }
            }
            var readings: [UUID: UsageSnapshot] = [:]
            var failures: [UUID: String] = [:]
            for (index, account) in settings.accounts.enumerated() {
                do {
                    let reading = try await runtime.fetch(account: account, settings: settings)
                    readings[account.id] = reading
                    let quotas = reading.windows.map { "\($0.name): \($0.remaining)% remaining" }.joined(separator: ", ")
                    let balances = reading.balances.map { "\($0.currency) \($0.available)" }.joined(separator: ", ")
                    print("LIVE account-\(index + 1) \(account.provider.rawValue): \(quotas)\(balances)")
                } catch {
                    failures[account.id] = error.localizedDescription
                    print("LIVE_UNAVAILABLE account-\(index + 1) \(account.provider.rawValue): \(error.localizedDescription)")
                }
            }
            let cache = LiveCache(readings: readings, errors: failures)
            let url = store.root.appendingPathComponent("usage-cache.json")
            try SecureFiles.write(JSONEncoder().encode(cache), to: url, expected: SecureFiles.read(url))
            if enableAutomation {
                let activeIDs = Array(settings.active.values)
                guard !activeIDs.isEmpty, activeIDs.allSatisfy({ readings[$0]?.isFresh(at: Date()) == true && failures[$0] == nil }) else {
                    throw AppFailure.message("Aut switching remains paused: not all active accounts have verified fresh usage.")
                }
                settings.automationPausedReason = nil
                settings.autoSwitch = true
                settings.restartCodex = true
                _ = try store.saveSettings(settings, expected: expected)
                print("AUTO_SWITCH_ENABLED threshold <=1%; Codex restart allowed. No switch executed by this command.")
            }
            print("RESULT \(readings.count) live reading(s), \(failures.count) unavailable. No account switching performed.")
        } catch {
            print("IMPORT_FAILED \(error.localizedDescription)")
        }
    }
}

struct LiveCache: Codable {
    var readings: [UUID: UsageSnapshot]
    var errors: [UUID: String]
}
