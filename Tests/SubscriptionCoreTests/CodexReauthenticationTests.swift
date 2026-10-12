import Foundation
import Testing
@testable import SubscriptionCore

struct CodexReauthenticationTests {
    static func credential(subject: String = "subject", user: String = "user", workspace: String = "workspace",
                           issued: Double, expiry: Double = Date().addingTimeInterval(3600).timeIntervalSince1970) throws -> CredentialEnvelope {
        let claims: JSONValue = .object(["sub": .string(subject), "iat": .number(issued), "exp": .number(expiry),
            "https://api.openai.com/auth": .object(["chatgpt_user_id": .string(user), "chatgpt_account_id": .string(workspace)])])
        let token = "fixture." + (try claims.data()).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        return try CredentialParser.parse(provider: .codex, data: JSONValue.object(["tokens": .object([
            "id_token": .string(token), "access_token": .string(token), "account_id": .string(workspace)
        ])]).data())
    }

    struct Fixture {
        let store = LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("CodexReauth-\(UUID())"))
        let vault = CodexAccountRecoveryTests.Vault()
        let account: Account
        let saved: CredentialEnvelope
        let settings: Settings
        let expected: Data
        let nativeURL: URL
        let nativeBytes = Data("working-native-login-must-not-change".utf8)
        init() throws {
            saved = try credential(issued: 100, expiry: 1000)
            account = Account(provider: .codex, label: "Expired login", identity: saved.identity, browserEnabled: true)
            nativeURL = store.root.appendingPathComponent("native/auth.json")
            var state = Settings(); state.accounts = [account]
            state.active[.codex] = UUID()
            state.codexHome = nativeURL.deletingLastPathComponent().path
            settings = state
            expected = try store.saveSettings(state, expected: nil)
            try SecureFiles.write(nativeBytes, to: nativeURL, expected: nil)
            try store.saveCredential(account.id, credential: saved, vault: vault)
        }
        func clean() { try? FileManager.default.removeItem(at: store.root) }
        func service(fetch: @escaping @Sendable (CredentialEnvelope) async throws -> UsageSnapshot = { _ in
            try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 20)], source: "test")
        }) -> CodexReauthentication { CodexReauthentication(store: store, vault: vault, fetch: fetch) }
    }

    @Test func successfulLoginReplacesOnlyTheSelectedSavedAccountAndPreservesNativeClient() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.service()
        let plan = try service.prepare(accountID: f.account.id, settings: f.settings, expected: f.expected)
        let candidate = try Self.credential(subject: "new-subject", issued: 200)

        let result = try await service.complete(plan, candidate: candidate)

        #expect(plan.workspaceID == "workspace")
        #expect(result.accountID == f.account.id)
        #expect(result.settings.accounts.count == 1)
        #expect(result.settings.accounts[0].label == f.account.label)
        #expect(result.settings.accounts[0].browserEnabled)
        #expect(result.settings.accounts[0].identity == candidate.identity)
        #expect(result.settings.active == f.settings.active)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault).primary == candidate.primary)
        #expect(try SecureFiles.read(f.nativeURL) == f.nativeBytes)
        #expect(result.reading.remainingPercent == 80)
    }

    @Test(arguments: ["user", "workspace", "expired", "older"])
    func unsafeCandidateNeverReachesUsageOrChangesSavedAccount(reason: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.service { _ in
            Issue.record("Unsafe candidate reached the usage provider")
            throw AppFailure.invalidUsage
        }
        let plan = try service.prepare(accountID: f.account.id, settings: f.settings, expected: f.expected)
        let candidate = try Self.credential(user: reason == "user" ? "foreign" : "user",
            workspace: reason == "workspace" ? "foreign" : "workspace", issued: reason == "older" ? 50 : 200,
            expiry: reason == "expired" ? 1000 : Date().addingTimeInterval(3600).timeIntervalSince1970)

        await #expect(throws: (any Error).self) { try await service.complete(plan, candidate: candidate) }

        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == f.saved)
        #expect(try SecureFiles.read(f.nativeURL) == f.nativeBytes)
    }

    @Test(arguments: [false, true])
    func rejectedOrStaleUsageCannotCommit(stale: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.service { _ in
            if !stale { throw AppFailure.invalidUsage }
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 20)],
                                     source: "test", fetchedAt: Date().addingTimeInterval(-3600))
        }
        let plan = try service.prepare(accountID: f.account.id, settings: f.settings, expected: f.expected)
        let candidate = try Self.credential(issued: 200)
        await #expect(throws: AppFailure.invalidUsage) { try await service.complete(plan, candidate: candidate) }
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == f.saved)
    }

    @Test(arguments: [false, true])
    func stateChangedWhileCheckingIsPreserved(vaultChanged: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        let newer = try Self.credential(issued: 300)
        let service = f.service { _ in
            if vaultChanged { try f.store.saveCredential(f.account.id, credential: newer, vault: f.vault) }
            else {
                var external = f.settings; external.accounts[0].label = "External edit"
                _ = try f.store.saveSettings(external, expected: f.expected)
            }
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 20)], source: "test")
        }
        let plan = try service.prepare(accountID: f.account.id, settings: f.settings, expected: f.expected)
        let candidate = try Self.credential(issued: 200)
        await #expect(throws: AppFailure.concurrentChange) { try await service.complete(plan, candidate: candidate) }
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == (vaultChanged ? newer : f.saved))
        #expect(try f.store.loadSettings().accounts[0].label == (vaultChanged ? f.account.label : "External edit"))
    }

    @Test func validationHasNoWritesAndCommitRechecksItsSnapshot() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.service()
        let plan = try service.prepare(accountID: f.account.id, settings: f.settings, expected: f.expected)
        let validation = try await service.validate(plan, candidate: Self.credential(issued: 200))
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == f.saved)
        var external = f.settings; external.selectedCodexClientID = UUID()
        let changed = try f.store.saveSettings(external, expected: f.expected)

        await #expect(throws: AppFailure.concurrentChange) { try await service.commit(validation) }

        #expect(try SecureFiles.read(f.store.settingsURL) == changed)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == f.saved)
    }

    @Test func failedVaultCommitRollsBackIdentityChange() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.service()
        let plan = try service.prepare(accountID: f.account.id, settings: f.settings, expected: f.expected)
        let candidate = try Self.credential(subject: "changed-subject", issued: 200)
        f.vault.failNextWrite = true
        await #expect(throws: (any Error).self) { try await service.complete(plan, candidate: candidate) }
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == f.saved)
    }

    @Test func cancelledVerificationCannotReachCommit() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = f.service { _ in
            try await Task.sleep(for: .seconds(10))
            throw AppFailure.invalidUsage
        }
        let plan = try service.prepare(accountID: f.account.id, settings: f.settings, expected: f.expected)
        let candidate = try Self.credential(issued: 200)
        let operation = Task { try await service.complete(plan, candidate: candidate) }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault) == f.saved)
    }
}
