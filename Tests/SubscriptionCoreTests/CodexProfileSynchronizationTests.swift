import Foundation
import Testing
@testable import SubscriptionCore

struct CodexProfileSynchronizationTests {
    final class Vault: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var lockOnWrite = false
        private var unavailable = false
        func read(_ key: String) throws -> Data? {
            try lock.withLock {
                if unavailable { throw KeychainAuthorizationError(target: .subscriptionVault, status: -25293) }
                return values[key]
            }
        }
        func write(_ key: String, data: Data) throws {
            lock.withLock {
                values[key] = data
                if lockOnWrite { unavailable = true }
            }
        }
        func remove(_ key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
        func compareAndSwap(key: String, expected: Data?, data: Data?) throws {
            try lock.withLock {
                if unavailable { throw KeychainAuthorizationError(target: .subscriptionVault, status: -25293) }
                guard values[key] == expected else { throw AppFailure.concurrentChange }
                values[key] = data
                if lockOnWrite { unavailable = true }
            }
        }
        func lockAfterNextWrite() { lock.withLock { lockOnWrite = true } }
    }

    final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CredentialEnvelope
        init(_ value: CredentialEnvelope) { self.value = value }
        func read() -> CredentialEnvelope { lock.withLock { value } }
        func replace(_ value: CredentialEnvelope) { lock.withLock { self.value = value } }
    }

    private func credential(subject: String, user: String, expiry: Double = 4_000_000_000) throws -> CredentialEnvelope {
        let claims: JSONValue = .object([
            "sub": .string(subject), "iat": .number(expiry - 3600), "exp": .number(expiry),
            "https://api.openai.com/auth": .object([
                "chatgpt_user_id": .string(user), "chatgpt_account_id": .string("workspace")
            ])
        ])
        let token = "fixture." + (try claims.data()).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
        return try CredentialParser.parse(provider: .codex, data: JSONValue.object(["tokens": .object([
            "id_token": .string(token), "access_token": .string(token), "account_id": .string("workspace")
        ])]).data())
    }

    struct Fixture {
        let store: LocalStore
        let vault = Vault()
        var settings: Settings
        let expected: Data
        init(saved: [CredentialEnvelope]) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexSync-\(UUID())")
            store = LocalStore(root: root)
            settings = Settings()
            settings.accounts = saved.enumerated().map { Account(provider: .codex, label: "Account \($0.offset)", identity: $0.element.identity) }
            settings.active[.codex] = settings.accounts.first?.id
            settings.codexClientProfiles = saved.indices.map {
                CodexClientProfile(name: "Client \($0)", home: root.appendingPathComponent("home-\($0)").path,
                                   applicationPath: "/Applications/Codex.app")
            }
            settings.selectedCodexClientID = settings.effectiveCodexProfiles.first?.id
            expected = try store.saveSettings(settings, expected: nil)
            for (account, envelope) in zip(settings.accounts, saved) {
                try store.saveCredential(account.id, credential: envelope, vault: vault)
            }
        }
        func clean() { try? FileManager.default.removeItem(at: store.root) }
    }

    @Test func twoHomesObserveTheirOwnSavedAccountsWithoutChangingSelection() async throws {
        let a = try credential(subject: "a", user: "alice")
        let b = try credential(subject: "b", user: "bob")
        let f = try Fixture(saved: [a, b]); defer { f.clean() }
        let profiles = f.settings.effectiveCodexProfiles
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { profile, _ in profile.id == profiles[0].id ? a : b },
            fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 12)], source: "test") })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.observations[profiles[0].id]?.accountID == f.settings.accounts[0].id)
        #expect(result.observations[profiles[1].id]?.accountID == f.settings.accounts[1].id)
        #expect(result.settings.active == f.settings.active)
        #expect(result.settings.selectedCodexClientID == profiles[0].id)
        #expect(result.settings.accounts == f.settings.accounts)
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
    }

    @Test func missingFirstHomeDoesNotBlockFreshInactiveSecondAccount() async throws {
        let a = try credential(subject: "a", user: "alice")
        let b = try credential(subject: "old-b", user: "bob")
        let freshB = try credential(subject: "new-b", user: "bob", expiry: 4_000_100_000)
        let f = try Fixture(saved: [a, b]); defer { f.clean() }
        let profiles = f.settings.effectiveCodexProfiles
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { profile, _ in
                if profile.id == profiles[0].id { throw AppFailure.missingCredential }
                return freshB
            }, fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 21)], source: "test") })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.observations[profiles[0].id]?.accountID == nil)
        #expect(result.observations[profiles[0].id]?.issue != nil)
        #expect(result.observations[profiles[1].id]?.accountID == f.settings.accounts[1].id)
        #expect(result.observations[profiles[1].id]?.issue == nil)
        #expect(result.readings[f.settings.accounts[1].id]?.remainingPercent == 79)
        #expect(try f.store.loadCredential(f.settings.accounts[1].id, vault: f.vault) == freshB)
        #expect(result.settings.active == f.settings.active)
        #expect(result.settings.selectedCodexClientID == profiles[0].id)
    }

    @Test func unknownCurrentUserIsNotImportedOrBoundToSavedAccount() async throws {
        let saved = try credential(subject: "a", user: "alice")
        let stranger = try credential(subject: "unknown", user: "stranger")
        let f = try Fixture(saved: [saved]); defer { f.clean() }
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { _, _ in stranger }, fetch: { _ in
                Issue.record("Unknown users must not be fetched or imported")
                throw AppFailure.invalidUsage
            })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.settings.accounts == f.settings.accounts)
        #expect(result.observations.values.allSatisfy { $0.accountID == nil && $0.issue != nil })
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == saved)
    }

    @Test func ambiguousStablePrincipalCannotUpdateEitherSavedAccount() async throws {
        let a = try credential(subject: "a", user: "same")
        let b = try credential(subject: "b", user: "same")
        let current = try credential(subject: "current", user: "same")
        let f = try Fixture(saved: [a, b]); defer { f.clean() }
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { _, _ in current }, fetch: { _ in
                Issue.record("Ambiguous principal must not contact provider")
                throw AppFailure.invalidUsage
            })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.observations.values.allSatisfy { $0.accountID == nil && $0.issue != nil })
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == a)
        #expect(try f.store.loadCredential(f.settings.accounts[1].id, vault: f.vault) == b)
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
    }

    @Test func staleClientCannotDowngradeNewerSavedLogin() async throws {
        let saved = try credential(subject: "a", user: "alice", expiry: 4_000_100_000)
        let stale = try credential(subject: "a", user: "alice", expiry: 4_000_000_000)
        let f = try Fixture(saved: [saved]); defer { f.clean() }
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { _, _ in stale }, fetch: { _ in
                Issue.record("Stale source must not replace saved login")
                throw AppFailure.invalidUsage
            })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.observations.values.first?.accountID == f.settings.accounts[0].id)
        #expect(result.observations.values.first?.issue == nil)
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == saved)
    }

    @Test func sourceChangesDuringUsageRequestPreventCredentialWrite() async throws {
        let saved = try credential(subject: "old", user: "alice")
        let fresh = try credential(subject: "fresh", user: "alice", expiry: 4_000_100_000)
        let other = try credential(subject: "other", user: "bob")
        let source = Source(fresh)
        let f = try Fixture(saved: [saved]); defer { f.clean() }
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { _, _ in source.read() }, fetch: { _ in
                source.replace(other)
                return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 7)], source: "test")
            })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.observations.values.first?.accountID == nil)
        #expect(result.observations.values.first?.issue != nil)
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == saved)
        #expect(try SecureFiles.read(f.store.settingsURL) == f.expected)
    }

    @Test func concurrentSettingsChangeReturnsActualStateAndStopsLaterWrites() async throws {
        let a = try credential(subject: "a", user: "alice")
        let b = try credential(subject: "b", user: "bob")
        let freshA = try credential(subject: "new-a", user: "alice", expiry: 4_000_100_000)
        let freshB = try credential(subject: "new-b", user: "bob", expiry: 4_000_100_000)
        let f = try Fixture(saved: [a, b]); defer { f.clean() }
        let profiles = f.settings.effectiveCodexProfiles
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { profile, _ in profile.id == profiles[0].id ? freshA : freshB }, fetch: { envelope in
                #expect(envelope == freshA)
                var changed = f.settings
                changed.autoSwitch = false
                _ = try f.store.saveSettings(changed, expected: f.expected)
                return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 7)], source: "test")
            })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.settings.autoSwitch == false)
        #expect(result.settingsData == (try SecureFiles.read(f.store.settingsURL)))
        #expect(result.observations.values.allSatisfy { $0.accountID == nil && $0.issue != nil })
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == a)
        #expect(try f.store.loadCredential(f.settings.accounts[1].id, vault: f.vault) == b)
    }

    @Test func partialTransactionReloadsCommittedSettingsAndStopsOtherProfiles() async throws {
        let a = try credential(subject: "a", user: "alice")
        let b = try credential(subject: "b", user: "bob")
        let freshA = try credential(subject: "new-a", user: "alice", expiry: 4_000_100_000)
        let freshB = try credential(subject: "new-b", user: "bob", expiry: 4_000_100_000)
        let f = try Fixture(saved: [a, b]); defer { f.clean() }
        let profiles = f.settings.effectiveCodexProfiles
        f.vault.lockAfterNextWrite()
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { profile, _ in profile.id == profiles[0].id ? freshA : freshB }, fetch: { envelope in
                #expect(envelope == freshA)
                return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 7)], source: "test")
            })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.settings.accounts[0].identity == freshA.identity)
        #expect(result.settings.accounts[1].identity == b.identity)
        #expect(result.settingsData == (try SecureFiles.read(f.store.settingsURL)))
        #expect(result.readings.isEmpty)
        #expect(result.observations.values.allSatisfy { $0.accountID == nil && $0.issue != nil })
    }

    @Test func rejectedUsageInFirstHomeDoesNotBlockSecondHomeRefresh() async throws {
        let a = try credential(subject: "a", user: "alice")
        let b = try credential(subject: "b", user: "bob")
        let freshA = try credential(subject: "new-a", user: "alice", expiry: 4_000_100_000)
        let freshB = try credential(subject: "new-b", user: "bob", expiry: 4_000_100_000)
        let f = try Fixture(saved: [a, b]); defer { f.clean() }
        let profiles = f.settings.effectiveCodexProfiles
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { profile, _ in profile.id == profiles[0].id ? freshA : freshB }, fetch: { envelope in
                if envelope == freshA { throw AppFailure.message("HTTP 401") }
                return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 7)], source: "test")
            })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.observations[profiles[0].id]?.issue != nil)
        #expect(result.observations[profiles[1].id]?.issue == nil)
        #expect(result.observations[profiles[1].id]?.accountID == f.settings.accounts[1].id)
        #expect(result.readings[f.settings.accounts[1].id]?.remainingPercent == 93)
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == a)
        #expect(try f.store.loadCredential(f.settings.accounts[1].id, vault: f.vault) == freshB)
    }

    @Test func twoRefreshesCarryCommittedSettingsForwardAcrossProfiles() async throws {
        let a = try credential(subject: "a", user: "alice")
        let b = try credential(subject: "b", user: "bob")
        let freshA = try credential(subject: "new-a", user: "alice", expiry: 4_000_100_000)
        let freshB = try credential(subject: "b", user: "bob", expiry: 4_000_100_000)
        let f = try Fixture(saved: [a, b]); defer { f.clean() }
        let profiles = f.settings.effectiveCodexProfiles
        let service = CodexProfileSynchronizer(store: f.store, vault: f.vault,
            capture: { profile, _ in profile.id == profiles[0].id ? freshA : freshB },
            fetch: { _ in try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 7)], source: "test") })
        let result = try await service.synchronize(settings: f.settings, expected: f.expected)
        #expect(result.readings.count == 2)
        #expect(result.observations.values.allSatisfy { $0.accountID != nil && $0.issue == nil })
        #expect(try f.store.loadCredential(f.settings.accounts[0].id, vault: f.vault) == freshA)
        #expect(try f.store.loadCredential(f.settings.accounts[1].id, vault: f.vault) == freshB)
        #expect(result.settingsData == (try SecureFiles.read(f.store.settingsURL)))
        #expect(result.settings.active == f.settings.active)
        #expect(result.settings.selectedCodexClientID == f.settings.selectedCodexClientID)
    }
}
