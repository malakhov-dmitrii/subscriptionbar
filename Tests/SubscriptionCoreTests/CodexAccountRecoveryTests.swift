import Foundation
import Testing
@testable import SubscriptionCore

struct CodexAccountRecoveryTests {
    final class Vault: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: Data] = [:]
        var failNextWrite = false
        var lockAfterNextWrite = false
        var unavailable = false
        func read(_ key: String) throws -> Data? {
            try lock.withLock {
                if unavailable { throw KeychainAuthorizationError(target: .subscriptionVault, status: -25293) }
                return entries[key]
            }
        }
        func write(_ key: String, data: Data) throws {
            try lock.withLock {
                if failNextWrite { failNextWrite = false; throw AppFailure.invalidCredential }
                entries[key] = data
                if lockAfterNextWrite { lockAfterNextWrite = false; unavailable = true }
            }
        }
        func remove(_ key: String) throws { _ = lock.withLock { entries.removeValue(forKey: key) } }
        func compareAndSwap(key: String, expected: Data?, data: Data?) throws {
            try lock.withLock {
                if unavailable { throw KeychainAuthorizationError(target: .subscriptionVault, status: -25293) }
                guard entries[key] == expected else { throw AppFailure.concurrentChange }
                if failNextWrite { failNextWrite = false; throw AppFailure.invalidCredential }
                entries[key] = data
                if lockAfterNextWrite { lockAfterNextWrite = false; unavailable = true }
            }
        }
    }

    private func credential(subject: String, user: String? = "stable-user", workspace: String = "workspace",
                            accessUser: String? = nil, expiry: Double? = nil, issued: Double? = nil) throws -> CredentialEnvelope {
        func token(_ stable: String?) throws -> String {
            var auth: [String: JSONValue] = ["chatgpt_account_id": .string(workspace)]
            if let stable { auth["chatgpt_user_id"] = .string(stable) }
            var payload: [String: JSONValue] = ["sub": .string(subject), "https://api.openai.com/auth": .object(auth)]
            if let expiry { payload["exp"] = .number(expiry) }
            if let issued { payload["iat"] = .number(issued) }
            return "fixture." + (try JSONValue.object(payload).data()).base64EncodedString()
                .replacingOccurrences(of: "=", with: "") + ".signature"
        }
        return try CredentialParser.parse(provider: .codex, data: JSONValue.object(["tokens": .object([
            "id_token": .string(token(user)), "access_token": .string(token(accessUser ?? user)),
            "account_id": .string(workspace)
        ])]).data())
    }

    struct Fixture {
        let store: LocalStore
        let vault = Vault()
        let account: Account
        var settings: Settings
        let expected: Data
        init(saved: CredentialEnvelope) throws {
            store = LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("CodexRecovery-\(UUID())"))
            account = Account(provider: .codex, label: "keep-label", identity: saved.identity, browserEnabled: true)
            settings = Settings()
            settings.accounts = [account]
            settings.active[.codex] = account.id
            expected = try store.saveSettings(settings, expected: nil)
            try store.saveCredential(account.id, credential: saved, vault: vault)
        }
        func clean() { try? FileManager.default.removeItem(at: store.root) }
    }

    @Test func changedOAuthSubjectRecoversSameAccountWithoutChangingClient() async throws {
        let saved = try credential(subject: "google-old"), current = try credential(subject: "auth0|new")
        let f = try Fixture(saved: saved); defer { f.clean() }
        let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
            fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 17)], source: "test") })

        let result = try #require(try await recovery.reconcile(settings: f.settings, expected: f.expected))

        #expect(result.settings.accounts.count == 1)
        #expect(result.settings.accounts[0].id == f.account.id)
        #expect(result.settings.accounts[0].label == "keep-label")
        #expect(result.settings.accounts[0].browserEnabled)
        #expect(result.settings.active == f.settings.active)
        #expect(result.settings.accounts[0].identity == current.identity)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == current)
        #expect(result.reading.remainingPercent == 83)
    }

    @Test func differentOrMissingStablePrincipalNeverMerges() async throws {
        let saved = try credential(subject: "google-old")
        for current in [try credential(subject: "new", user: "other"),
                        try credential(subject: "new", user: nil),
                        try credential(subject: "new", workspace: "other"),
                        try credential(subject: "new", accessUser: "other")] {
            let f = try Fixture(saved: saved); defer { f.clean() }
            let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
                fetch: { _ in Issue.record("Must not contact usage for an unproven match"); throw AppFailure.invalidCredential })
            #expect(try await recovery.reconcile(settings: f.settings, expected: f.expected) == nil)
            #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
            #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == saved)
        }
    }

    @Test func failedUsageAndConcurrentSettingsLeaveSavedLoginUntouched() async throws {
        let saved = try credential(subject: "old"), current = try credential(subject: "new")
        let f = try Fixture(saved: saved); defer { f.clean() }
        let failed = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
            fetch: { _ in throw AppFailure.invalidUsage })
        await #expect(throws: AppFailure.invalidUsage) { try await failed.reconcile(settings: f.settings, expected: f.expected) }
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == saved)

        let changed = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current }, fetch: { _ in
            var settings = f.settings; settings.autoSwitch = false
            _ = try f.store.saveSettings(settings, expected: f.expected)
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 17)], source: "test")
        })
        await #expect(throws: AppFailure.concurrentChange) { try await changed.reconcile(settings: f.settings, expected: f.expected) }
        #expect(try f.store.loadSettings().autoSwitch == false)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == saved)
    }

    @Test func failedVaultWriteRollsBackSettingsAndInterruptedSettingsWriteRecovers() async throws {
        let saved = try credential(subject: "old"), current = try credential(subject: "new")
        let f = try Fixture(saved: saved); defer { f.clean() }
        let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
            fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 17)], source: "test") })
        f.vault.failNextWrite = true
        await #expect(throws: AppFailure.invalidCredential) { try await recovery.reconcile(settings: f.settings, expected: f.expected) }
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == saved)

        var interrupted = f.settings; interrupted.accounts[0].identity = current.identity
        let expected = try f.store.saveSettings(interrupted, expected: f.expected)
        #expect(try await recovery.reconcile(settings: interrupted, expected: expected) != nil)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == current)
    }

    @Test func explicitRecaptureMatchesInactiveAccountButBackgroundDoesNot() async throws {
        let saved = try credential(subject: "old"), current = try credential(subject: "new")
        let f = try Fixture(saved: saved); defer { f.clean() }
        let other = try credential(subject: "other", user: "other-user")
        let active = Account(provider: .codex, label: "active", identity: other.identity)
        var settings = f.settings; settings.accounts.append(active); settings.active[.codex] = active.id
        let expected = try f.store.saveSettings(settings, expected: f.expected)
        try f.store.saveCredential(active.id, credential: other, vault: f.vault)
        let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
            fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 17)], source: "test") })
        #expect(try await recovery.reconcile(settings: settings, expected: expected) == nil)
        let result = try #require(try await recovery.reconcile(settings: settings, expected: expected, matchingCurrent: true))
        #expect(result.settings.accounts.count == 2)
        #expect(result.accountID == f.account.id)
        #expect(result.settings.active[.codex] == active.id)
        #expect(try f.store.loadCredential(active.id, vault: f.vault) == other)
    }

    @Test func duplicatePrincipalAndChangedClientNeverWrite() async throws {
        let saved = try credential(subject: "old"), current = try credential(subject: "new")
        let f = try Fixture(saved: saved); defer { f.clean() }
        var settings = f.settings
        let duplicate = Account(provider: .codex, label: "duplicate", identity: saved.identity)
        settings.accounts.append(duplicate)
        let expected = try f.store.saveSettings(settings, expected: f.expected)
        try f.store.saveCredential(duplicate.id, credential: saved, vault: f.vault)
        let duplicateRecovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
            fetch: { _ in Issue.record("Duplicate must fail before networking"); throw AppFailure.invalidCredential })
        await #expect(throws: AppFailure.invalidCredential) {
            try await duplicateRecovery.reconcile(settings: settings, expected: expected)
        }
        #expect(try SecureFiles.read(f.store.settingsURL) == expected)

        let client = f.store.root.appendingPathComponent("client.json")
        try SecureFiles.write(current.primary, to: client, expected: nil)
        let reset = try f.store.saveSettings(f.settings, expected: expected)
        let changed = try credential(subject: "changed", user: "other-user")
        let clientRecovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in
            guard let data = try SecureFiles.read(client) else { throw AppFailure.missingCredential }
            return try CredentialParser.parse(provider: .codex, data: data)
        }, fetch: { _ in
            try SecureFiles.write(changed.primary, to: client, expected: current.primary)
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 17)], source: "test")
        })
        await #expect(throws: AppFailure.concurrentChange) {
            try await clientRecovery.reconcile(settings: f.settings, expected: reset)
        }
        #expect(try SecureFiles.read(f.store.settingsURL) == reset)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == saved)
        #expect(try SecureFiles.read(client) == changed.primary)
    }

    @Test func unchangedLegacySubjectNeedsNoStableClaimsAndExpiryIsExplicit() async throws {
        let saved = try credential(subject: "legacy", user: nil)
        let f = try Fixture(saved: saved); defer { f.clean() }
        let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in saved },
            fetch: { _ in Issue.record("Unchanged binding uses normal fetch"); throw AppFailure.invalidCredential })
        #expect(try await recovery.reconcile(settings: f.settings, expected: f.expected) == nil)
        let now = Date(timeIntervalSince1970: 100)
        #expect(CodexAccountRecovery.isExpired(try credential(subject: "x", expiry: 100), now: now))
        #expect(!CodexAccountRecovery.isExpired(try credential(subject: "x", expiry: 101), now: now))
        #expect(!CodexAccountRecovery.isExpired(saved, now: now))
    }

    @Test func keychainLockAfterWriteCannotRollSettingsBackToAnUnrecoverableBinding() async throws {
        let saved = try credential(subject: "old"), current = try credential(subject: "new")
        let f = try Fixture(saved: saved); defer { f.clean() }
        let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
            fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 17)], source: "test") })
        f.vault.lockAfterNextWrite = true
        await #expect(throws: (any Error).self) { try await recovery.reconcile(settings: f.settings, expected: f.expected) }
        f.vault.unavailable = false
        let settings = try f.store.loadSettings()
        let credential = try f.store.loadCredential(f.account.id, vault: f.vault)
        #expect(settings.accounts[0].identity == credential.identity)
        #expect(settings.accounts[0].id == f.account.id)
        #expect(credential == current)
        let expected = try SecureFiles.read(f.store.settingsURL)
        #expect(try await recovery.reconcile(settings: settings, expected: expected) == nil)
    }

    @Test func newerNativeTokenRefreshesSameIdentityWithoutChangingAccount() async throws {
        let saved = try credential(subject: "same", expiry: 4_000_000_000, issued: 100)
        let current = try credential(subject: "same", expiry: 4_000_000_100, issued: 200)
        let f = try Fixture(saved: saved); defer { f.clean() }
        let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current },
            fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 17)], source: "test") })
        let result = try #require(try await recovery.reconcile(settings: f.settings, expected: f.expected, matchingCurrent: true))
        #expect(result.settings.accounts == f.settings.accounts)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == current)
    }

    @Test func olderClientCopyNeverDowngradesNewerSavedCredentials() async throws {
        let saved = try credential(subject: "same", expiry: 4_000_000_100, issued: 200)
        let current = try credential(subject: "same", expiry: 4_000_000_000, issued: 100)
        let f = try Fixture(saved: saved); defer { f.clean() }
        let recovery = CodexAccountRecovery(store: f.store, vault: f.vault, capture: { _ in current }, fetch: { _ in
            Issue.record("An older credential must not overwrite the newer one even if its quota is readable")
            throw AppFailure.invalidCredential
        })
        #expect(try await recovery.reconcile(settings: f.settings, expected: f.expected, matchingCurrent: true) == nil)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == saved)
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
    }
}
