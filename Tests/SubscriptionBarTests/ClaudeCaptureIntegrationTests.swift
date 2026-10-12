import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor struct ClaudeCaptureIntegrationTests {
    final class Secrets: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [KeychainItemSelector: Data] = [:]
        func set(_ selector: KeychainItemSelector, _ value: Data) { lock.withLock { entries[selector] = value } }
        func get(_ selector: KeychainItemSelector) -> Data? { lock.withLock { entries[selector] } }
        func client() -> KeychainClient {
            KeychainClient(snapshotReader: { [self] selector, _, interactive in
                #expect(!interactive)
                return get(selector).map { KeychainItemSnapshot(selector: selector, persistentReference: Data("test".utf8), data: $0) }
            }, writer: { [self] selector, value in set(selector, value) })
        }
    }

    nonisolated static let accountA = "00000000-0000-4000-8000-000000000001"
    nonisolated static let accountB = "00000000-0000-4000-8000-000000000002"
    nonisolated static let orgA = "00000000-0000-4000-8000-000000000011"
    nonisolated static let orgB = "00000000-0000-4000-8000-000000000012"

    nonisolated static func metadata(_ user: String, _ org: String, _ email: String) -> JSONValue {
        .object(["accountUuid": .string(user), "organizationUuid": .string(org), "emailAddress": .string(email)])
    }
    nonisolated static func payload(_ token: String) throws -> Data {
        try JSONValue.object(["claudeAiOauth": .object(["accessToken": .string(token)])]).data()
    }
    nonisolated static func profile(_ user: String, _ org: String, _ email: String) throws -> Data {
        try JSONValue.object(["account": .object(["uuid": .string(user), "email": .string(email)]),
                              "organization": .object(["uuid": .string(org)])]).data()
    }

    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCapture-\(UUID())")
        let secrets = Secrets()
        let store: LocalStore
        let vault: KeychainVault
        let nativeSelector: KeychainItemSelector
        let configURL: URL
        let configBytes: Data
        let nativeBytes: Data
        let oldAccount: Account
        let oldCredential: CredentialEnvelope
        let settings: Settings

        init() throws {
            store = LocalStore(root: root.appendingPathComponent("store"))
            vault = KeychainVault(root: store.root, client: secrets.client())
            var state = Settings(); state.claudeHome = root.appendingPathComponent("claude").path
            state.enabledProviders = [.claude]; state.autoSwitch = false
            let oldMetadata = metadata(accountA, orgA, "old@example.test")
            oldCredential = try CredentialParser.parse(provider: .claude, data: payload("fixture-A"), metadata: oldMetadata)
            oldAccount = Account(provider: .claude, label: "Saved old account", identity: oldCredential.identity)
            state.accounts = [oldAccount]; state.active[.claude] = oldAccount.id
            settings = state
            configURL = URL(fileURLWithPath: state.claudeHome).appendingPathComponent(".claude.json")
            configBytes = try JSONValue.object(["oauthAccount": oldMetadata]).data()
            try SecureFiles.write(configBytes, to: configURL, expected: nil)
            nativeBytes = try payload("fixture-B")
            nativeSelector = try CLIConnector(settings: state).claudeKeychainSelector()
            secrets.set(nativeSelector, nativeBytes)
            _ = try store.saveSettings(state, expected: nil)
            try store.saveCredential(oldAccount.id, credential: oldCredential, vault: vault)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func runtime(profileFetcher: ClaudeIdentityVerifier.ProfileFetcher? = nil) -> AccountRuntime {
            AccountRuntime(store: store, keychain: secrets.client(), vault: vault,
                claudeIdentity: ClaudeIdentityVerifier(fetchProfile: profileFetcher ?? { token in
                    #expect(token == "fixture-B")
                    return try profile(accountB, orgB, "new@example.test")
                }), fetchUsage: { request in
                    try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: request.bearer == "fixture-B" ? 30 : 80)], source: "fixture")
                })
        }
    }

    @Test func savingWorkingTokenWithStaleMetadataCreatesActualAccountAndKeepsItsQuotasReadable() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = AppModel(demo: false, store: f.store, runtime: f.runtime(), startPolling: false, notificationSender: { _ in })
        model.credentialAccess = .ready

        #expect(await model.add(provider: .claude, label: "pro x5", apiKey: ""))

        let added = try #require(model.settings.accounts.first { $0.id != f.oldAccount.id })
        #expect(added.identity == Self.accountB)
        #expect(added.label == "pro x5")
        #expect(model.settings.active[.claude] == added.id)
        #expect(try f.store.loadCredential(f.oldAccount.id, vault: f.vault) == f.oldCredential)
        #expect(try f.store.loadCredential(added.id, vault: f.vault).metadata?["emailAddress"]?.string == "new@example.test")
        #expect(try SecureFiles.read(f.configURL) == f.configBytes)
        #expect(f.secrets.get(f.nativeSelector) == f.nativeBytes)

        await model.refresh()

        #expect(model.errors[added.id] == nil)
        #expect(model.readings[added.id]?.remainingPercent == 70)
        #expect(model.readings[f.oldAccount.id]?.remainingPercent == 20)
        #expect(try SecureFiles.read(f.configURL) == f.configBytes)
    }

    @Test func recapturePreservesOnlyTheSameVerifiedAccountsBrowserSession() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runtime = f.runtime()
        let captured = try await runtime.capture(provider: .claude, settings: f.settings, apiKey: "")
        let account = Account(provider: .claude, label: "New", identity: captured.identity)
        var previous = captured
        previous.webSessionKey = "fixture-web-session"
        previous.webOrganizationID = Self.orgB
        try f.store.saveCredential(account.id, credential: previous, vault: f.vault)

        try await runtime.save(account: account, credential: captured)

        let saved = try f.store.loadCredential(account.id, vault: f.vault)
        #expect(saved.webSessionKey == previous.webSessionKey)
        #expect(saved.webOrganizationID == previous.webOrganizationID)
        await #expect(throws: AppFailure.invalidCredential) { try await runtime.save(account: f.oldAccount, credential: captured) }
        #expect(try f.store.loadCredential(f.oldAccount.id, vault: f.vault) == f.oldCredential)
    }

    @Test func sourceChangedDuringProviderCheckCannotBeSaved() async throws {
        let f = try Fixture(); defer { f.clean() }
        let external = try Self.payload("external-change")
        let runtime = f.runtime(profileFetcher: { _ in
            f.secrets.set(f.nativeSelector, external)
            return try Self.profile(Self.accountB, Self.orgB, "new@example.test")
        })
        await #expect(throws: AppFailure.concurrentChange) {
            try await runtime.capture(provider: .claude, settings: f.settings, apiKey: "")
        }
        #expect(f.secrets.get(f.nativeSelector) == external)
        #expect(try SecureFiles.read(f.configURL) == f.configBytes)
        #expect(try f.store.loadSettings().accounts == f.settings.accounts)
        #expect(try f.store.loadCredential(f.oldAccount.id, vault: f.vault) == f.oldCredential)
    }

    @Test func rotatedTokenKeepsVerifiedOwnerDespiteStaleMetadata() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runtime = f.runtime(profileFetcher: { _ in try Self.profile(Self.accountB, Self.orgB, "new@example.test") })
        let saved = try await runtime.capture(provider: .claude, settings: f.settings, apiKey: "")
        let account = Account(provider: .claude, label: "B", identity: saved.identity)
        try f.store.saveCredential(account.id, credential: saved, vault: f.vault)
        var settings = f.settings; settings.accounts.append(account); settings.active[.claude] = account.id
        let rotated = try Self.payload("fixture-B-rotated")
        f.secrets.set(f.nativeSelector, rotated)

        _ = try await runtime.fetch(account: account, settings: settings)

        let updated = try f.store.loadCredential(account.id, vault: f.vault)
        #expect(updated.primary == rotated)
        #expect(updated.identity == Self.accountB)
        #expect(updated.metadata?["organizationUuid"]?.string == Self.orgB)
        #expect(try SecureFiles.read(f.configURL) == f.configBytes)
    }

    @Test func nativeSwitchUsesRawSnapshotForCASAndVerifiedIdentityForOwnership() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runtime = f.runtime(profileFetcher: { token in
            if token == "fixture-B" { return try Self.profile(Self.accountB, Self.orgB, "new@example.test") }
            if token == "fixture-A" { return try Self.profile(Self.accountA, Self.orgA, "old@example.test") }
            throw AppFailure.invalidCredential
        })
        let current = try await runtime.capture(provider: .claude, settings: f.settings, apiKey: "")
        let account = Account(provider: .claude, label: "B", identity: current.identity)
        try f.store.saveCredential(account.id, credential: current, vault: f.vault)
        var settings = f.settings; settings.accounts.append(account); settings.active[.claude] = account.id

        try await runtime.switchNative(to: f.oldAccount, from: account, settings: settings)

        #expect(f.secrets.get(f.nativeSelector) == f.oldCredential.primary)
        #expect(try CLIConnector(settings: settings, keychain: f.secrets.client()).capture(.claude).identity == Self.accountA)
        #expect(try f.store.loadCredential(account.id, vault: f.vault).identity == Self.accountB)
        #expect(try f.store.loadCredential(account.id, vault: f.vault).primary == current.primary)
    }

    @Test func sameUserInDifferentOrganizationCannotReplaceSavedBinding() async throws {
        let f = try Fixture(); defer { f.clean() }
        let runtime = f.runtime()
        let captured = try await runtime.capture(provider: .claude, settings: f.settings, apiKey: "")
        let account = Account(provider: .claude, label: "B", identity: captured.identity)
        try f.store.saveCredential(account.id, credential: captured, vault: f.vault)
        var foreignWorkspace = captured
        foreignWorkspace.metadata = Self.metadata(Self.accountB, Self.orgA, "new@example.test")
        await #expect(throws: AppFailure.invalidCredential) { try await runtime.save(account: account, credential: foreignWorkspace) }
        #expect(try f.store.loadCredential(account.id, vault: f.vault) == captured)
    }
}
