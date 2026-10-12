import Foundation
import Testing
@testable import SubscriptionCore

struct CodexImportMergeTests {
    final class Vault: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Data] = [:]
        private var concurrentValue: Data?
        private var failVerification = false
        private var failNextRead = false
        func read(_ key: String) throws -> Data? {
            try lock.withLock {
                if failNextRead { failNextRead = false; throw AppFailure.invalidCredential }
                return entries[key]
            }
        }
        func write(_ key: String, data: Data) throws { lock.withLock { entries[key] = data } }
        func remove(_ key: String) throws { _ = lock.withLock { entries.removeValue(forKey: key) } }
        func compareAndSwap(key: String, expected: Data?, data: Data?) throws {
            try lock.withLock {
                if let concurrentValue { entries[key] = concurrentValue; self.concurrentValue = nil }
                guard entries[key] == expected else { throw AppFailure.concurrentChange }
                entries[key] = data
                if failVerification { failVerification = false; failNextRead = true }
            }
        }
        func replaceBeforeNextCAS(with data: Data) { lock.withLock { concurrentValue = data } }
        func failVerificationAfterNextCAS() { lock.withLock { failVerification = true } }
        var isEmpty: Bool { lock.withLock { entries.isEmpty } }
    }

    struct Fixture {
        let store: LocalStore
        let vault = Vault()
        let settings: Settings
        let expected: Data?
        init(saved: CredentialEnvelope?) throws {
            store = LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("CodexImportMerge-\(UUID())"))
            var settings = Settings()
            settings.autoSwitch = false
            if let saved {
                let account = Account(provider: .codex, label: "Keep label", identity: saved.identity,
                                      browserEnabled: true, enabled: false)
                settings.accounts = [account]
                expected = try store.saveSettings(settings, expected: nil)
                try store.saveCredential(account.id, credential: saved, vault: vault)
            } else { expected = nil }
            self.settings = settings
        }
        func clean() { try? FileManager.default.removeItem(at: store.root) }
    }

    private func credential(subject: String = "subject", user: String = "user", issued: Double?) throws -> CredentialEnvelope {
        var payload: [String: JSONValue] = ["sub": .string(subject), "https://api.openai.com/auth": .object([
            "chatgpt_user_id": .string(user), "chatgpt_account_id": .string("workspace")
        ])]
        if let issued { payload["iat"] = .number(issued); payload["exp"] = .number(issued + 3600) }
        let token = "fixture." + (try JSONValue.object(payload).data()).base64EncodedString()
            .replacingOccurrences(of: "=", with: "") + ".signature"
        return try CredentialParser.parse(provider: .codex, data: JSONValue.object(["tokens": .object([
            "id_token": .string(token), "access_token": .string(token), "account_id": .string("workspace")
        ])]).data())
    }

    @Test func staleImportedSnapshotPreservesNewerSavedLoginAndWebFields() throws {
        var saved = try credential(issued: 4_000_100_000)
        saved.webSessionKey = "saved-web"
        saved.webOrganizationID = "saved-organization"
        let old = try credential(issued: 4_000_000_000)
        #expect(try CodexCredentialMerge.preferred(incoming: old, saved: saved) == saved)
    }

    @Test func provenFreshSnapshotKeepsSavedBrowserBinding() throws {
        var saved = try credential(issued: 4_000_000_000)
        saved.webSessionKey = "saved-web"
        saved.webOrganizationID = "saved-organization"
        var incoming = try credential(issued: 4_000_100_000)
        incoming.webSessionKey = "incoming-web"
        let result = try CodexCredentialMerge.preferred(incoming: incoming, saved: saved)
        #expect(result.primary == incoming.primary)
        #expect(result.identity == incoming.identity)
        #expect(result.webSessionKey == "saved-web")
        #expect(result.webOrganizationID == "saved-organization")
    }

    @Test func equalOrUnknownGenerationPreservesSavedBytes() throws {
        let saved = try credential(issued: nil)
        var incoming = saved
        incoming.webSessionKey = "new-web"
        #expect(try CodexCredentialMerge.preferred(incoming: incoming, saved: saved) == saved)
        let dated = try credential(issued: 4_000_000_000)
        #expect(try CodexCredentialMerge.preferred(incoming: saved, saved: dated) == dated)
    }

    @Test func expiredIncomingLoginCannotReplaceSavedLogin() throws {
        let saved = try credential(issued: nil)
        let expired = try credential(issued: 1_000)
        #expect(try CodexCredentialMerge.preferred(incoming: expired, saved: saved) == saved)
    }

    @Test func contradictoryPrincipalCannotOverwriteSameSubjectOrCreateDuplicate() throws {
        let saved = try credential(user: "alice", issued: 4_000_000_000)
        let conflict = try credential(user: "bob", issued: 4_000_100_000)
        let account = Account(provider: .codex, label: "Keep me", identity: saved.identity)
        #expect(throws: AppFailure.invalidCredential) {
            try CodexCredentialMerge.preferred(incoming: conflict, saved: saved)
        }
        #expect(throws: AppFailure.invalidCredential) {
            try CodexCredentialMerge.existingAccount(incoming: conflict, accounts: [account], savedCredentials: [account.id: saved])
        }
    }

    @Test func stableDuplicatePrincipalsRejectInsteadOfPickingOneAccount() throws {
        let a = try credential(subject: "first", issued: 4_000_000_000)
        let b = try credential(subject: "second", issued: 4_000_000_000)
        let incoming = try credential(subject: "new", issued: 4_000_100_000)
        let first = Account(provider: .codex, label: "First", identity: a.identity)
        let second = Account(provider: .codex, label: "Second", identity: b.identity)
        #expect(throws: AppFailure.invalidCredential) {
            try CodexCredentialMerge.existingAccount(incoming: incoming, accounts: [first, second],
                                                     savedCredentials: [first.id: a, second.id: b])
        }
    }

    @Test func importedOldSubjectResolvesExistingUUIDWithoutChangingAccountSettings() throws {
        let saved = try credential(subject: "new-sub", issued: 4_000_100_000)
        let old = try credential(subject: "old-sub", issued: 4_000_000_000)
        var account = Account(provider: .codex, label: "Keep label", identity: saved.identity, browserEnabled: true, enabled: false)
        account.balanceThreshold = 42
        let existing = try #require(try CodexCredentialMerge.existingAccount(incoming: old, accounts: [account],
                                                                        savedCredentials: [account.id: saved]))
        #expect(existing == account)
        #expect(existing.id == account.id)
        #expect(try CodexCredentialMerge.preferred(incoming: old, saved: saved) == saved)
    }

    @Test func missingSavedCredentialOrInterruptedIdentityCannotCreateDuplicate() throws {
        let saved = try credential(issued: 4_000_000_000)
        var account = Account(provider: .codex, label: "Keep label", identity: saved.identity)
        #expect(throws: AppFailure.invalidCredential) {
            try CodexCredentialMerge.existingAccount(incoming: saved, accounts: [account], savedCredentials: [:])
        }
        account.identity = "interrupted-migration"
        #expect(throws: AppFailure.invalidCredential) {
            try CodexCredentialMerge.existingAccount(incoming: saved, accounts: [account], savedCredentials: [account.id: saved])
        }
    }

    @Test func legacySubjectMigrationResolvesSameSavedAccount() throws {
        let saved = try credential(subject: "old", issued: nil)
        let incoming = try credential(subject: "new", issued: nil)
        let account = Account(provider: .codex, label: "Keep label", identity: saved.identity)
        #expect(try CodexCredentialMerge.existingAccount(incoming: incoming, accounts: [account],
                                                        savedCredentials: [account.id: saved])?.id == account.id)
        #expect(try CodexCredentialMerge.preferred(incoming: incoming, saved: saved).identity == incoming.identity)
    }

    @Test func committedStaleImportPreservesUUIDLabelDisabledStateAndNewerLogin() throws {
        let saved = try credential(subject: "new", issued: 4_000_100_000)
        let old = try credential(subject: "old", issued: 4_000_000_000)
        let f = try Fixture(saved: saved); defer { f.clean() }
        let result = try CodexCredentialMerge.commit(incoming: old, label: "Do not rename", makeActive: false,
            settings: f.settings, expected: f.expected, store: f.store, vault: f.vault)
        #expect(result.isNew == false)
        #expect(result.settings.accounts == f.settings.accounts)
        #expect(result.account == f.settings.accounts[0])
        #expect(result.settings.autoSwitch == false)
        #expect(result.credential == saved)
        #expect(try f.store.loadCredential(result.account.id, vault: f.vault) == saved)
        #expect(try f.store.loadSettings().accounts.count == 1)
    }

    @Test func freshSameIdentityCommitKeepsBrowserFieldsAndAccountSettings() throws {
        var saved = try credential(issued: 4_000_000_000)
        saved.webSessionKey = "keep-web"
        saved.webOrganizationID = "keep-org"
        let fresh = try credential(issued: 4_000_100_000)
        let f = try Fixture(saved: saved); defer { f.clean() }
        let result = try CodexCredentialMerge.commit(incoming: fresh, label: "Do not rename", makeActive: true,
            settings: f.settings, expected: f.expected, store: f.store, vault: f.vault)
        #expect(result.credential.primary == fresh.primary)
        #expect(result.credential.webSessionKey == "keep-web")
        #expect(result.credential.webOrganizationID == "keep-org")
        #expect(result.account == f.settings.accounts[0])
        #expect(result.settings.active[.codex] == result.account.id)
        #expect(result.settings.autoSwitch == false)
        #expect(try SecureFiles.read(f.store.settingsURL) == result.settingsData)
    }

    @Test func identityMigrationIsRefusedWithoutWritingOrDuplicatingAccount() throws {
        let saved = try credential(subject: "old", issued: 4_000_000_000)
        let fresh = try credential(subject: "new", issued: 4_000_100_000)
        let f = try Fixture(saved: saved); defer { f.clean() }
        #expect(throws: AppFailure.concurrentChange) {
            try CodexCredentialMerge.commit(incoming: fresh, label: "New", makeActive: true,
                settings: f.settings, expected: f.expected, store: f.store, vault: f.vault)
        }
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == saved)
    }

    @Test func concurrentNewerVaultWriteWinsOverPreparedImport() throws {
        let saved = try credential(issued: 4_000_000_000)
        let incoming = try credential(issued: 4_000_100_000)
        let newest = try credential(issued: 4_000_200_000)
        let f = try Fixture(saved: saved); defer { f.clean() }
        f.vault.replaceBeforeNextCAS(with: try JSONEncoder().encode(newest))
        #expect(throws: AppFailure.self) {
            try CodexCredentialMerge.commit(incoming: incoming, label: "Do not rename", makeActive: false,
                settings: f.settings, expected: f.expected, store: f.store, vault: f.vault)
        }
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == newest)
        #expect(try f.store.loadSettings().accounts == f.settings.accounts)
    }

    @Test func externalSettingsEditPreventsAllCredentialWrites() throws {
        let saved = try credential(issued: 4_000_000_000)
        let fresh = try credential(issued: 4_000_100_000)
        let f = try Fixture(saved: saved); defer { f.clean() }
        var external = f.settings
        external.warnThreshold = 37
        let externalData = try f.store.saveSettings(external, expected: f.expected)
        #expect(throws: AppFailure.concurrentChange) {
            try CodexCredentialMerge.commit(incoming: fresh, label: "Do not rename", makeActive: false,
                settings: f.settings, expected: f.expected, store: f.store, vault: f.vault)
        }
        #expect(try SecureFiles.read(f.store.settingsURL) == externalData)
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == saved)
    }

    @Test func failedNewAccountVerificationRollsBackNewVaultKeyAndSettingsFile() throws {
        let incoming = try credential(issued: 4_000_000_000)
        let f = try Fixture(saved: nil); defer { f.clean() }
        f.vault.failVerificationAfterNextCAS()
        #expect(throws: AppFailure.invalidCredential) {
            try CodexCredentialMerge.commit(incoming: incoming, label: "New", makeActive: true,
                settings: f.settings, expected: f.expected, store: f.store, vault: f.vault)
        }
        #expect(try SecureFiles.read(f.store.settingsURL) == nil)
        #expect(f.vault.isEmpty)
    }

    @Test func newAccountCommitPublishesMatchingSettingsAndCredential() throws {
        let incoming = try credential(issued: 4_000_000_000)
        let f = try Fixture(saved: nil); defer { f.clean() }
        let result = try CodexCredentialMerge.commit(incoming: incoming, label: "New", makeActive: true,
            settings: f.settings, expected: f.expected, store: f.store, vault: f.vault)
        #expect(result.isNew)
        #expect(result.settings.accounts == [result.account])
        #expect(result.account.label == "New")
        #expect(result.settings.active[.codex] == result.account.id)
        #expect(result.settings.autoSwitch == false)
        #expect(try f.store.loadCredential(result.account.id, vault: f.vault) == incoming)
        #expect(try SecureFiles.read(f.store.settingsURL) == result.settingsData)
    }
}
