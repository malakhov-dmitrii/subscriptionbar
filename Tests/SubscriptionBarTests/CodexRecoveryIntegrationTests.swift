import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor struct CodexRecoveryIntegrationTests {
    private func isExpiredMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        // Other UI suites exercise the process-global language in parallel.
        return message.contains("expired") || message.contains("истёк")
    }
    final class Raw: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        func client() -> KeychainClient {
            KeychainClient(snapshotReader: { [self] selector, _, interactive in
                #expect(!interactive)
                return lock.withLock {
                    data.map { KeychainItemSnapshot(selector: selector, persistentReference: Data("test".utf8), data: $0) }
                }
            }, writer: { [self] _, value in lock.withLock { data = value } })
        }
    }
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexIntegration-\(UUID())")
        let store: LocalStore
        let vault: KeychainVault
        let active: Account
        let inactive: Account
        let inactiveCredential: CredentialEnvelope
        init(expires: Double = 100) throws {
            store = LocalStore(root: root)
            let raw = Raw()
            vault = KeychainVault(root: root, client: raw.client())
            func credential(_ subject: String) throws -> CredentialEnvelope {
                let payload: JSONValue = .object(["sub": .string(subject), "exp": .number(expires),
                    "https://api.openai.com/auth": .object(["chatgpt_user_id": .string(subject),
                        "chatgpt_account_id": .string("workspace")])])
                let token = "fixture." + (try payload.data()).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
                return try CredentialParser.parse(provider: .codex, data: JSONValue.object(["tokens": .object([
                    "id_token": .string(token), "access_token": .string(token), "account_id": .string("workspace")
                ])]).data())
            }
            let activeCredential = try credential("active")
            inactiveCredential = try credential("inactive")
            active = Account(provider: .codex, label: "active", identity: activeCredential.identity)
            inactive = Account(provider: .codex, label: "inactive", identity: inactiveCredential.identity)
            var settings = Settings()
            settings.accounts = [active, inactive]
            settings.enabledProviders = [.codex]
            settings.active[.codex] = active.id
            settings.codexHome = root.appendingPathComponent("client").path
            settings.autoSwitch = false
            _ = try store.saveSettings(settings, expected: nil)
            try store.saveCredential(active.id, credential: activeCredential, vault: vault)
            try store.saveCredential(inactive.id, credential: inactiveCredential, vault: vault)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func missingCurrentLoginDoesNotSuppressInactiveAccountError() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runtime = AccountRuntime(store: f.store, vault: f.vault)
        let model = AppModel(demo: false, store: f.store, runtime: runtime, startPolling: false)
        model.credentialAccess = .ready
        await model.refresh()
        #expect(model.errors[f.active.id] != nil)
        #expect(isExpiredMessage(model.errors[f.inactive.id]))
        #expect(model.settings.active[.codex] == nil)
    }

    @Test func missingCurrentLoginDoesNotAbortOtherLiveChecks() async throws {
        let f = try Fixture(); defer { f.clean() }
        await ImportCommand.run(importAccounts: false, store: f.store, vault: f.vault)
        let cacheData = try #require(try SecureFiles.read(f.store.root.appendingPathComponent("usage-cache.json")))
        let cache = try JSONDecoder().decode(LiveCache.self, from: cacheData)
        #expect(cache.errors[f.active.id] != nil)
        #expect(isExpiredMessage(cache.errors[f.inactive.id]))
    }

    @Test func explicitCaptureMarksTheAlreadySignedInClientWithoutAddingDuplicate() async throws {
        let f = try Fixture(expires: 4_000_000_000); defer { f.clean() }
        let settings = try f.store.loadSettings()
        let client = URL(fileURLWithPath: settings.codexHome).appendingPathComponent("auth.json")
        try SecureFiles.write(f.inactiveCredential.primary, to: client, expected: nil)
        let model = AppModel(demo: false, store: f.store,
            runtime: AccountRuntime(store: f.store, vault: f.vault, fetchUsage: { _ in
                try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 25)], source: "test")
            }), startPolling: false)
        model.credentialAccess = .ready
        #expect(await model.add(provider: .codex, label: "inactive", apiKey: ""))
        #expect(model.settings.accounts.count == 2)
        #expect(model.settings.active[.codex] == f.inactive.id)
        #expect(try SecureFiles.read(client) == f.inactiveCredential.primary)
    }

    @Test func recoveryFailureReloadsCommittedSettingsBeforeNextPoll() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = AppModel(demo: false, store: f.store,
            runtime: AccountRuntime(store: f.store, vault: f.vault), startPolling: false)
        model.credentialAccess = .ready
        var committed = try f.store.loadSettings()
        committed.accounts[0].identity = "committed-identity"
        let expected = try SecureFiles.read(f.store.settingsURL)
        _ = try f.store.saveSettings(committed, expected: expected)
        await model.refresh()
        #expect(model.settings.accounts[0].identity == "committed-identity")
    }
}
