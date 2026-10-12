import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor
struct CredentialRecoveryTests {
    final class FakeKeychain: @unchecked Sendable {
        enum Mode { case denyBackground, cancel, succeed, missing, failReadBack, ordinary }
        struct Call: Sendable { let interactive: Bool; let persistent: Bool }
        private let lock = NSLock()
        private var current: Mode = .denyBackground
        private var recorded: [Call] = []
        private var writeCount = 0
        private var delay: TimeInterval = 0
        private var ownVaultDenied = false
        private let reference = Data("persistent-reference".utf8)
        let credential: Data

        init(credential: Data) { self.credential = credential }
        var mode: Mode {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
        var calls: [Call] { lock.withLock { recorded } }
        var writes: Int { lock.withLock { writeCount } }
        var interactiveDelay: TimeInterval {
            get { lock.withLock { delay } }
            set { lock.withLock { delay = newValue } }
        }
        var denyOwnVault: Bool {
            get { lock.withLock { ownVaultDenied } }
            set { lock.withLock { ownVaultDenied = newValue } }
        }

        func client() -> KeychainClient {
            KeychainClient(snapshotReader: { [self] selector, persistent, interactive in
                if selector.service == KeychainVault.defaultService {
                    if lock.withLock({ ownVaultDenied }) { throw KeychainAccessError(status: -25293) }
                    return nil
                }
                let mode = lock.withLock { () -> Mode in
                    recorded.append(Call(interactive: interactive, persistent: persistent != nil))
                    return current
                }
                if interactive {
                    let wait = lock.withLock { delay }
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                }
                if interactive, mode == .cancel { throw KeychainAccessError(status: -128) }
                if !interactive, persistent == nil, mode == .denyBackground {
                    throw KeychainAccessError(status: -25293)
                }
                if !interactive, persistent != nil, mode == .failReadBack {
                    throw KeychainAccessError(status: -25308)
                }
                if interactive, mode == .missing { return nil }
                if mode == .ordinary { throw AppFailure.invalidCredential }
                return KeychainItemSnapshot(selector: selector, persistentReference: reference, data: credential)
            }, writer: { [self] _, _ in lock.withLock { writeCount += 1 } })
        }
    }

    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialRecoveryTests-\(UUID())")
        let claudeHome: URL
        let store: LocalStore
        let keychain: FakeKeychain
        let model: AppModel

        @MainActor init() throws {
            claudeHome = root.appendingPathComponent("claude")
            try FileManager.default.createDirectory(at: claudeHome, withIntermediateDirectories: true)
            let metadata = try JSONValue.object(["oauthAccount": .object(["accountUuid": .string("account-A")])]).data()
            try metadata.write(to: claudeHome.appendingPathComponent(".claude.json"))
            let payload = try JSONValue.object(["sub": .string("account-A")]).data()
            let token = "h." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
            let credentials = try JSONValue.object(["claudeAiOauth": .object(["accessToken": .string(token)])]).data()
            keychain = FakeKeychain(credential: credentials)
            store = LocalStore(root: root.appendingPathComponent("app"))
            let runtime = AccountRuntime(store: store, keychain: keychain.client())
            model = AppModel(demo: false, store: store, runtime: runtime, startPolling: false)
            model.settings.claudeHome = claudeHome.path
            model.credentialAccess = .ready
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func realAddCaptureFailureKeepsExactTargetAndShowsZeroAccountRecovery() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }

        #expect(await fixture.model.add(provider: .claude, label: "first", apiKey: "") == false)

        let event = try #require(fixture.model.credentialAccess.authorizationEvent)
        let expected = try CLIConnector(settings: fixture.model.settings,
                                        keychain: fixture.keychain.client()).claudeKeychainSelector()
        #expect(event.target == .claudeCode(expected))
        #expect(fixture.model.settings.accounts.isEmpty)
        #expect(fixture.model.credentialAccess.button != nil)
        #expect(fixture.model.credentialAccess.showsBanner(hasAccounts: false))
        #expect(fixture.model.lastResult.contains("-25293"))
        #expect(fixture.keychain.writes == 0)
    }

    @Test func cancellationKeepsSameGenerationAndNeverRetriesOrWrites() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = await fixture.model.add(provider: .claude, label: "first", apiKey: "")
        let before = try #require(fixture.model.credentialAccess.authorizationEvent)
        fixture.keychain.mode = .cancel

        await fixture.model.authorizeAccounts()

        let after = try #require(fixture.model.credentialAccess.authorizationEvent)
        #expect(after.generation == before.generation)
        #expect(fixture.keychain.calls.filter(\.interactive).count == 1)
        #expect(fixture.keychain.writes == 0)
    }

    @Test func verifiedReadBackClearsOnlyTheMatchingFailureAndResumes() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = await fixture.model.add(provider: .claude, label: "first", apiKey: "")
        fixture.keychain.mode = .succeed

        await fixture.model.authorizeAccounts()

        #expect(fixture.model.credentialAccess == .ready)
        #expect(fixture.model.lastResult.isEmpty)
        #expect(fixture.keychain.calls.filter(\.interactive).count == 1)
        #expect(fixture.keychain.calls.contains { !$0.interactive && $0.persistent })
        #expect(fixture.keychain.writes == 0)
    }

    @Test func failedReadBackAndMissingItemHaveDifferentTerminalStates() async throws {
        let locked = try Fixture(); defer { locked.clean() }
        _ = await locked.model.add(provider: .claude, label: "first", apiKey: "")
        let generation = try #require(locked.model.credentialAccess.authorizationEvent).generation
        locked.keychain.mode = .failReadBack
        await locked.model.authorizeAccounts()
        #expect(try #require(locked.model.credentialAccess.authorizationEvent).generation == generation)

        let missing = try Fixture(); defer { missing.clean() }
        _ = await missing.model.add(provider: .claude, label: "first", apiKey: "")
        missing.keychain.mode = .missing
        await missing.model.authorizeAccounts()
        #expect(missing.model.credentialAccess == .ready)
        #expect(!missing.model.lastResult.isEmpty)
        #expect(missing.keychain.writes == 0)
    }

    @Test func ordinaryCaptureFailureDoesNotClaimAuthorizationIsRequired() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        fixture.model.settings.claudeHome = fixture.root.appendingPathComponent("missing").path

        #expect(await fixture.model.add(provider: .claude, label: "first", apiKey: "") == false)
        #expect(fixture.model.credentialAccess == .ready)
        #expect(fixture.model.credentialAccess.button == nil)
    }

    @Test func changedClaudeHomeRejectsStaleTargetBeforeAnyPrompt() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = await fixture.model.add(provider: .claude, label: "first", apiKey: "")
        fixture.model.settings.claudeHome = fixture.root.appendingPathComponent("different-home").path
        fixture.keychain.mode = .succeed

        await fixture.model.authorizeAccounts()

        #expect(fixture.model.credentialAccess == .ready)
        #expect(!fixture.model.lastResult.isEmpty)
        #expect(fixture.keychain.calls.filter(\.interactive).isEmpty)
    }

    @Test func concurrentClicksAreCoalescedByAppModelBusyState() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        _ = await fixture.model.add(provider: .claude, label: "first", apiKey: "")
        fixture.keychain.mode = .succeed
        fixture.keychain.interactiveDelay = 0.1

        async let first: Void = fixture.model.authorizeAccounts()
        await Task.yield()
        async let second: Void = fixture.model.authorizeAccounts()
        _ = await (first, second)

        #expect(fixture.keychain.calls.filter(\.interactive).count == 1)
    }

    @Test func failedSecretCleanupCannotRemoveTheAccountFromSettings() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let account = Account(provider: .deepSeek, label: "keep-me", identity: "fixture")
        fixture.model.settings.accounts = [account]
        fixture.model.settings.active[.deepSeek] = account.id
        fixture.model.settings.enabledProviders.insert(.deepSeek)
        fixture.model.persist()
        fixture.keychain.denyOwnVault = true

        await fixture.model.delete(account.id)

        #expect(fixture.model.settings.accounts.contains { $0.id == account.id })
        #expect(fixture.model.settings.active[.deepSeek] == account.id)
        #expect(fixture.model.credentialAccess.authorizationEvent?.target == .subscriptionVault)
    }
}

private extension CredentialAccess {
    var authorizationEvent: CredentialAuthorizationEvent? {
        if case .authorizationRequired(let event) = self { return event }
        return nil
    }
}
