import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor struct CodexSelectedSwitchTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
    struct Setup {
        let fixture: CodexMonitoringTests.Fixture
        let first: CodexClientProfile
        let second: CodexClientProfile
        let runtime: AccountRuntime
        let settings: Settings
        let expected: Data
        let otherBytes: Data
        init(otherUsesTarget: Bool = false) throws {
            let f = try CodexMonitoringTests.Fixture()
            fixture = f
            first = CodexClientProfile(name: "One", home: f.root.appendingPathComponent("one").path, applicationPath: "/Applications/Codex.app")
            second = CodexClientProfile(name: "Two", home: f.root.appendingPathComponent("two").path, applicationPath: "/Applications/codex2.app")
            var configured = f.settings
            configured.codexClientProfiles = [first, second]
            configured.selectedCodexClientID = first.id
            settings = configured
            expected = try f.store.saveSettings(configured, expected: SecureFiles.read(f.store.settingsURL))
            otherBytes = try otherUsesTarget ? f.credentialB.primary : CodexMonitoringTests.Fixture.credential("C").primary
            try SecureFiles.write(f.credentialA.primary, to: URL(fileURLWithPath: first.home).appendingPathComponent("auth.json"), expected: nil)
            try SecureFiles.write(otherBytes, to: URL(fileURLWithPath: second.home).appendingPathComponent("auth.json"), expected: nil)
            runtime = AccountRuntime(store: f.store, vault: f.vault, fetchUsage: { _ in
                try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 25)], source: "test")
            })
        }
        var firstURL: URL { URL(fileURLWithPath: first.home).appendingPathComponent("auth.json") }
        var secondURL: URL { URL(fileURLWithPath: second.home).appendingPathComponent("auth.json") }
    }

    @Test func commitChangesOnlySelectedHomeAndPreservesBothSavedAccounts() async throws {
        let s = try Setup(); defer { s.fixture.clean() }
        let plan = try await s.runtime.prepareCodexSwitch(to: s.fixture.b, settings: s.settings, expected: s.expected)
        let result = try await s.runtime.commitCodexSwitch(plan)
        #expect(try SecureFiles.read(s.firstURL) == s.fixture.credentialB.primary)
        #expect(try SecureFiles.read(s.secondURL) == s.otherBytes)
        #expect(result.settings.active[.codex] == s.fixture.b.id)
        #expect(result.settings.selectedCodexClientID == s.first.id)
        #expect(try s.fixture.store.loadCredential(s.fixture.a.id, vault: s.fixture.vault) == s.fixture.credentialA)
        #expect(try s.fixture.store.loadCredential(s.fixture.b.id, vault: s.fixture.vault) == s.fixture.credentialB)
    }

    @Test func accountAlreadyOwnedByAnotherProfileCannotBeCopied() async throws {
        let s = try Setup(otherUsesTarget: true); defer { s.fixture.clean() }
        await #expect(throws: (any Error).self) {
            try await s.runtime.prepareCodexSwitch(to: s.fixture.b, settings: s.settings, expected: s.expected)
        }
        #expect(try SecureFiles.read(s.firstURL) == s.fixture.credentialA.primary)
        #expect(try SecureFiles.read(s.secondURL) == s.fixture.credentialB.primary)
    }

    @Test func changedSourceOrSettingsAbortBeforeCredentialWrite() async throws {
        for changeSettings in [true, false] {
            let s = try Setup(); defer { s.fixture.clean() }
            let plan = try await s.runtime.prepareCodexSwitch(to: s.fixture.b, settings: s.settings, expected: s.expected)
            if changeSettings {
                var external = s.settings; external.warnThreshold = 44
                _ = try s.fixture.store.saveSettings(external, expected: s.expected)
            } else {
                try SecureFiles.write(s.otherBytes, to: s.firstURL, expected: s.fixture.credentialA.primary)
            }
            let before = try SecureFiles.read(s.firstURL)
            await #expect(throws: AppFailure.concurrentChange) { try await s.runtime.commitCodexSwitch(plan) }
            #expect(try SecureFiles.read(s.firstURL) == before)
            #expect(try SecureFiles.read(s.secondURL) == s.otherBytes)
        }
    }

    @Test func newOwnershipInAnotherHomeAndStaleQuotaInvalidatePreflight() async throws {
        let s = try Setup(); defer { s.fixture.clean() }
        let plan = try await s.runtime.prepareCodexSwitch(to: s.fixture.b, settings: s.settings, expected: s.expected)
        try SecureFiles.write(s.fixture.credentialB.primary, to: s.secondURL, expected: s.otherBytes)
        await #expect(throws: AppFailure.concurrentChange) { try await s.runtime.commitCodexSwitch(plan) }
        try SecureFiles.write(s.otherBytes, to: s.secondURL, expected: s.fixture.credentialB.primary)
        let stale = try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 25)], source: "test", fetchedAt: .distantPast)
        let expiredPlan = CodexSwitchPlan(profile: plan.profile, target: plan.target, destination: plan.destination,
            before: plan.before, settings: plan.settings, expectedSettings: plan.expectedSettings, reading: stale)
        await #expect(throws: AppFailure.concurrentChange) { try await s.runtime.commitCodexSwitch(expiredPlan) }
        #expect(try SecureFiles.read(s.firstURL) == s.fixture.credentialA.primary)
    }

    @Test func ephemeralStorageCannotUseAStaleFileAsSwitchTarget() throws {
        let s = try Setup(); defer { s.fixture.clean() }
        let configuration = URL(fileURLWithPath: s.first.home).appendingPathComponent("config.toml")
        try SecureFiles.write(Data("cli_auth_credentials_store = \"ephemeral\"\n".utf8), to: configuration, expected: nil)
        #expect(throws: (any Error).self) {
            try CLIConnector(settings: s.settings.settings(forCodexProfile: s.first)).capture(.codex)
        }
    }

    @Test func switchPersistsRecoveryPauseBeforeAnyExternalTransition() async throws {
        let s = try Setup(); defer { s.fixture.clean() }
        let store = s.fixture.store
        let runtime = AccountRuntime(store: store, vault: s.fixture.vault, fetchUsage: { _ in
            #expect(try store.loadSettings().automationPausedReason != nil)
            // Stop at the read-only quota boundary; native clients are never called.
            throw AppFailure.invalidUsage
        })
        let model = AppModel(demo: false, store: store, runtime: runtime, startPolling: false, notificationSender: { _ in })
        model.credentialAccess = .ready
        await model.switchAccount(s.fixture.b.id)
        #expect(try store.loadSettings().automationPausedReason != nil)
        #expect(try SecureFiles.read(s.firstURL) == s.fixture.credentialA.primary)
        #expect(try SecureFiles.read(s.secondURL) == s.otherBytes)
    }

    @Test(arguments: [true, false]) func autoRotationRechecksUserLoginAfterQuotaRequests(signedIntoC: Bool) async throws {
        let f = try CodexMonitoringTests.Fixture(); defer { f.clean() }
        let credentialC = try CodexMonitoringTests.Fixture.credential("C")
        let c = Account(provider: .codex, label: "C", identity: credentialC.identity)
        try f.store.saveCredential(c.id, credential: credentialC, vault: f.vault)
        var settings = f.settings; settings.accounts.append(c); settings.autoSwitch = true
        _ = try f.store.saveSettings(settings, expected: SecureFiles.read(f.store.settingsURL))
        try SecureFiles.write(f.credentialA.primary, to: f.clientURL, expected: nil)
        let targetRequests = Counter()
        let runtime = AccountRuntime(store: f.store, vault: f.vault, fetchUsage: { request in
            let subject = CredentialParser.jwt(request.bearer)?["sub"]?.string
            if subject == "A" {
                if signedIntoC { try SecureFiles.write(credentialC.primary, to: f.clientURL, expected: f.credentialA.primary) }
                else { try SecureFiles.remove(f.clientURL, expected: f.credentialA.primary) }
            }
            // On old code a second B request is switch preflight. Refuse there
            // so a regression can never reach native process control in this test.
            if subject == "B", targetRequests.next() > 1 { throw AppFailure.invalidUsage }
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: subject == "A" ? 100 : 25)], source: "test")
        })
        let model = AppModel(demo: false, store: f.store, runtime: runtime, startPolling: false, notificationSender: { _ in })
        model.credentialAccess = .ready
        await model.refresh()
        #expect(model.settings.active[.codex] == (signedIntoC ? c.id : nil))
        #expect(model.settings.automationPausedReason == nil)
        #expect(try SecureFiles.read(f.clientURL) == (signedIntoC ? credentialC.primary : nil))
    }
}
