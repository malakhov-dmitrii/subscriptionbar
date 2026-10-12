import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor
@Suite(.serialized)
struct CodexReauthenticationModelTests {
    final class VaultRaw: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var blockNext = false
        private var blocked = false
        private let gate = DispatchSemaphore(value: 0)
        func blockNextWrite() { lock.withLock { blockNext = true } }
        var isBlocked: Bool { lock.withLock { blocked } }
        func resume() { gate.signal() }
        func client() -> KeychainClient {
            KeychainClient(snapshotReader: { [self] selector, _, interactive in
                #expect(!interactive)
                return lock.withLock {
                    data.map { KeychainItemSnapshot(selector: selector, persistentReference: Data("model-fixture".utf8), data: $0) }
                }
            }, writer: { [self] _, value in
                let shouldBlock = lock.withLock {
                    let result = blockNext
                    blockNext = false
                    if result { blocked = true }
                    return result
                }
                if shouldBlock {
                    guard gate.wait(timeout: .now() + 5) == .success else { throw AppFailure.concurrentChange }
                }
                lock.withLock { data = value; blocked = false }
            })
        }
    }

    struct Fixture {
        let store: LocalStore
        let raw = VaultRaw()
        let vault: KeychainVault
        let account: Account
        let other: Account
        let saved: CredentialEnvelope
        let candidate: CredentialEnvelope
        let native: CredentialEnvelope
        let nativeURL: URL
        let expected: Data
        let process: CodexLoginSessionTests.Fixture

        init(user: String = "A", waitForCancel: Bool = false, deviceCode: Bool = false, restartAllowed: Bool = true) throws {
            store = LocalStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("CodexReauthModel-\(UUID())"))
            vault = KeychainVault(root: store.root, client: raw.client())
            saved = try CodexMonitoringTests.Fixture.credential("A", issued: 100, expires: 1000)
            let incoming = try CodexMonitoringTests.Fixture.credential(user, issued: 200)
            candidate = incoming
            native = try CodexMonitoringTests.Fixture.credential("B")
            account = Account(provider: .codex, label: "Saved A", identity: saved.identity)
            other = Account(provider: .codex, label: "Working B", identity: native.identity)
            nativeURL = store.root.appendingPathComponent("native/auth.json")
            var settings = Settings()
            settings.accounts = [account, other]
            settings.active[.codex] = other.id
            settings.codexHome = nativeURL.deletingLastPathComponent().path
            settings.enabledProviders = [.codex]
            settings.autoSwitch = false
            settings.restartCodex = restartAllowed
            expected = try store.saveSettings(settings, expected: nil)
            try store.saveCredential(account.id, credential: saved, vault: vault)
            try store.saveCredential(other.id, credential: native, vault: vault)
            try SecureFiles.write(native.primary, to: nativeURL, expected: nil)
            process = try CodexLoginSessionTests.Fixture { script in
                var lines = script.components(separatedBy: "\n")
                lines[lines.count - 1] = "printf '%s' '\(String(decoding: incoming.primary, as: UTF8.self))' > \"$CODEX_HOME/auth.json\""
                var result = lines.joined(separator: "\n")
                if waitForCancel {
                    result = result.replacingOccurrences(of: "printf '%s\\n' '{\"method\":\"account/login/completed\"",
                        with: "IFS= read -r cancelRequest\nprintf '%s\\n' '{\"method\":\"account/login/completed\"")
                }
                if deviceCode {
                    result = result.replacingOccurrences(of: "\"type\":\"chatgpt\",\"loginId\":\"fixture-login\",\"authUrl\":\"https://auth.openai.com/oauth/authorize?fixture=1\"",
                        with: "\"type\":\"chatgptDeviceCode\",\"loginId\":\"fixture-login\",\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"TEST-CODE\"")
                }
                return result
            }
        }
        @MainActor func model(fetch: @escaping @Sendable (UsageCredential) async throws -> UsageSnapshot = { _ in
            try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 20)], source: "fixture")
        }) -> AppModel {
            let runtime = AccountRuntime(store: store, vault: vault, fetchUsage: fetch)
            let model = AppModel(demo: false, store: store, runtime: runtime, startPolling: false, notificationSender: { _ in })
            model.credentialAccess = .ready
            return model
        }
        @MainActor func session() -> CodexLoginSession {
            CodexLoginSession(testExecutable: process.executable, stagingBase: process.staging,
                              timeout: .seconds(5), startupTimeout: .seconds(2))
        }
        func clean() { process.clean(); try? FileManager.default.removeItem(at: store.root) }
        func expectUnchanged() throws {
            #expect(try SecureFiles.read(store.settingsURL) == expected)
            #expect(try store.loadCredential(account.id, vault: vault) == saved)
            #expect(try store.loadCredential(other.id, vault: vault) == native)
            #expect(try SecureFiles.read(nativeURL) == native.primary)
        }
    }

    actor UsageGate {
        private(set) var entered = false
        func fetch() async throws -> UsageSnapshot {
            entered = true
            try await Task.sleep(for: .seconds(20))
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 20)], source: "fixture")
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppFailure.message("Recovery fixture did not reach its expected state.")
    }

    @Test func openingAndClosingReadyRecoveryOnlyOwnsBusyState() throws {
        let fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        let runtime = AccountRuntime(store: fixture.store, vault: fixture.vault, fetchUsage: { _ in
            Issue.record("Opening the recovery window must not contact a provider")
            throw AppFailure.invalidUsage
        })
        let model = AppModel(demo: false, store: fixture.store, runtime: runtime, startPolling: false)
        model.credentialAccess = .ready
        let expected = try SecureFiles.read(fixture.store.settingsURL)
        let controller = try #require(model.beginCodexReauthentication(fixture.a.id,
            openBrowser: { _ in Issue.record("Opening the recovery window must not open a browser") }, presentWindow: false))
        #expect(model.busy)
        #expect(controller.phase == .ready)
        #expect(controller.requestClose())
        #expect(model.codexReauthentication == nil)
        #expect(!model.busy)
        #expect(try SecureFiles.read(fixture.store.settingsURL) == expected)
        #expect(try fixture.store.loadCredential(fixture.a.id, vault: fixture.vault) == fixture.credentialA)
    }

    @Test func browserSuccessUpdatesSameUUIDAndLeavesWorkingNativeClientUntouched() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = f.model()
        let session = f.session()
        var opened = 0
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: session,
            openBrowser: { url in #expect(url.host == "auth.openai.com"); opened += 1 }, presentWindow: false))
        controller.start(method: .browser, switchAfterSignIn: false)
        try await waitUntil { if case .succeeded = controller.phase { true } else { false } }
        #expect(opened == 1)
        #expect(session.isIdle)
        #expect(!model.busy)
        #expect(model.settings.accounts.count == 2)
        #expect(model.settings.accounts[0].id == f.account.id)
        #expect(model.settings.active[.codex] == f.other.id)
        #expect(model.readings[f.account.id]?.remainingPercent == 80)
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault).primary == f.candidate.primary)
        #expect(try SecureFiles.read(f.nativeURL) == f.native.primary)
        #expect(try f.store.loadCredential(f.other.id, vault: f.vault) == f.native)
        model.busy = true // Another operation now owns busy after recovery completed.
        #expect(controller.requestClose())
        #expect(model.busy)
        model.busy = false
    }

    @Test func closingAwaitingLoginCancelsBeforeRacedSuccessAndReleasesBusy() async throws {
        let f = try Fixture(waitForCancel: true); defer { f.clean() }
        let model = f.model()
        let session = f.session()
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: session,
            openBrowser: { _ in }, presentWindow: false))
        controller.start(method: .browser, switchAfterSignIn: false)
        try await waitUntil { if case .awaiting = controller.phase { true } else { false } }
        #expect(!controller.requestClose())
        #expect(controller.phase == .cancelling)
        try await waitUntil { model.codexReauthentication == nil }
        #expect(!model.busy)
        #expect(session.isIdle)
        try f.expectUnchanged()
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.process.staging.path).isEmpty)
    }

    @Test func cancelWhileCheckingStopsBeforeAnyCredentialCommit() async throws {
        let f = try Fixture(); defer { f.clean() }
        let gate = UsageGate()
        let model = f.model { _ in try await gate.fetch() }
        let session = f.session()
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: session,
            openBrowser: { _ in }, presentWindow: false))
        controller.start(method: .browser, switchAfterSignIn: false)
        try await waitUntil { await gate.entered }
        #expect(controller.phase == .checking)
        controller.cancel()
        try await waitUntil { model.codexReauthentication == nil }
        #expect(session.isIdle)
        #expect(!model.busy)
        try f.expectUnchanged()
    }

    @Test func wrongAccountFailsWithoutRelabelingOrChangingEitherSavedAccount() async throws {
        let f = try Fixture(user: "B"); defer { f.clean() }
        let model = f.model { _ in Issue.record("Foreign login must not reach usage validation"); throw AppFailure.invalidUsage }
        let session = f.session()
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: session,
            openBrowser: { _ in }, presentWindow: false))
        controller.start(method: .browser, switchAfterSignIn: false)
        try await waitUntil { if case .failed = controller.phase { true } else { false } }
        #expect(model.busy)
        #expect(session.isIdle)
        try f.expectUnchanged()
        #expect(controller.requestClose())
        #expect(!model.busy)
    }

    @Test func saveBoundaryRejectsCancelAndWindowCloseUntilCommitFinishes() async throws {
        let f = try Fixture(); defer { f.raw.resume(); f.clean() }
        let model = f.model()
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: f.session(),
            openBrowser: { _ in }, presentWindow: false))
        f.raw.blockNextWrite()
        controller.start(method: .browser, switchAfterSignIn: false)
        try await waitUntil { f.raw.isBlocked }
        #expect(controller.phase == .saving)
        #expect(!controller.requestClose())
        #expect(await controller.prepareForAppTermination() == false)
        controller.cancel()
        #expect(controller.phase == .saving)
        #expect(model.busy)
        f.raw.resume()
        try await waitUntil { if case .succeeded = controller.phase { true } else { false } }
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault).primary == f.candidate.primary)
        #expect(try SecureFiles.read(f.nativeURL) == f.native.primary)
        #expect(controller.requestClose())
    }

    @Test func deviceCodeRequiresExplicitBrowserOpenAndCancelLeavesSavedState() async throws {
        let f = try Fixture(waitForCancel: true, deviceCode: true); defer { f.clean() }
        let model = f.model()
        var opens = 0
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: f.session(),
            openBrowser: { _ in opens += 1 }, presentWindow: false))
        controller.start(method: .deviceCode, switchAfterSignIn: false)
        try await waitUntil { if case .awaiting = controller.phase { true } else { false } }
        guard case .awaiting(let instructions) = controller.phase else { Issue.record("Missing instructions"); return }
        #expect(instructions.userCode == "TEST-CODE")
        #expect(opens == 0)
        controller.open(instructions.url)
        #expect(opens == 1)
        controller.cancel()
        try await waitUntil { model.codexReauthentication == nil }
        try f.expectUnchanged()
    }

    @Test func changedSelectedProfilePreventsLaunchingAndOnlyOneDialogOwnsModel() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = f.model()
        let session = f.session()
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: session,
            openBrowser: { _ in Issue.record("Changed profile must not open browser") }, presentWindow: false))
        #expect(model.beginCodexReauthentication(f.other.id, presentWindow: false) === controller)
        model.settings.codexHome = f.store.root.appendingPathComponent("changed").path
        controller.start(method: .browser, switchAfterSignIn: false)
        try await waitUntil { if case .failed = controller.phase { true } else { false } }
        #expect(session.isIdle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.process.staging.path).isEmpty)
        try f.expectUnchanged()
        #expect(controller.requestClose())
    }

    @Test func demoUsesFakeInstructionsAndNeverLaunchesLoginOrBrowser() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = AppModel(demo: true, store: f.store, startPolling: false)
        let account = try #require(model.settings.accounts.first(where: { $0.provider == .codex }))
        let session = f.session()
        let before = model.settings.accounts
        let controller = try #require(model.beginCodexReauthentication(account.id, session: session,
            openBrowser: { _ in Issue.record("Demo must not open a browser") }, presentWindow: false))
        controller.start(method: .deviceCode, switchAfterSignIn: true)
        try await waitUntil { if case .awaiting = controller.phase { true } else { false } }
        guard case .awaiting(let instructions) = controller.phase else { Issue.record("Missing demo instructions"); return }
        #expect(instructions.userCode == "DEMO-CODE")
        controller.open(instructions.url)
        #expect(model.settings.accounts == before)
        #expect(session.isIdle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.process.staging.path).isEmpty)
        try f.expectUnchanged()
        #expect(controller.requestClose())
    }

    @Test func failedOptionalActivationReportsSavedLoginSeparatelyWithoutTouchingNativeHome() async throws {
        let f = try Fixture(restartAllowed: false); defer { f.clean() }
        let model = f.model()
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: f.session(),
            openBrowser: { _ in }, presentWindow: false))
        controller.start(method: .browser, switchAfterSignIn: true)
        try await waitUntil { if case .succeeded = controller.phase { true } else { false } }
        guard case .succeeded(let message) = controller.phase else { Issue.record("Missing saved-login result"); return }
        #expect(message.contains(L10n.ui("Sign-in saved, but switching the selected profile failed.")))
        #expect(try f.store.loadCredential(f.account.id, vault: f.vault).primary == f.candidate.primary)
        #expect(model.settings.active[.codex] == f.other.id)
        #expect(model.settings.automationPausedReason != nil)
        #expect(try SecureFiles.read(f.nativeURL) == f.native.primary)
        #expect(!model.busy)
        #expect(controller.requestClose())
    }

    @Test(arguments: [false, true])
    func appTerminationWaitsForOwnedProcessCleanupWithoutCredentialWrites(alreadyCancelling: Bool) async throws {
        let f = try Fixture(waitForCancel: true); defer { f.clean() }
        let model = f.model()
        let session = f.session()
        let controller = try #require(model.beginCodexReauthentication(f.account.id, session: session,
            openBrowser: { _ in }, presentWindow: false))
        controller.start(method: .browser, switchAfterSignIn: false)
        try await waitUntil { if case .awaiting = controller.phase { true } else { false } }
        #expect(!session.isIdle)
        if alreadyCancelling { controller.cancel() }
        #expect(await controller.prepareForAppTermination())
        #expect(session.isIdle)
        #expect(model.codexReauthentication == nil)
        #expect(!model.busy)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.process.staging.path).isEmpty)
        try f.expectUnchanged()
    }
}
