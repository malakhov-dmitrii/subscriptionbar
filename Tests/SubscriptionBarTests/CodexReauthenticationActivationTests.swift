import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor struct CodexReauthenticationActivationTests {
    @Test func explicitRecoveryOfActiveAccountStillRunsGuardedPreflight() async throws {
        let f = try CodexMonitoringTests.Fixture(); defer { f.clean() }
        try SecureFiles.write(f.credentialA.primary, to: f.clientURL, expected: nil)
        let refreshed = try CodexMonitoringTests.Fixture.credential("A", issued: 1_800_000_000)
        try f.store.saveCredential(f.a.id, credential: refreshed, vault: f.vault)
        let runtime = AccountRuntime(store: f.store, vault: f.vault, fetchUsage: { _ in
            throw AppFailure.message("reauth-preflight-stop")
        })
        let model = AppModel(demo: false, store: f.store, runtime: runtime, startPolling: false, notificationSender: { _ in })
        model.credentialAccess = .ready

        let switched = await model.performCodexSwitch(f.a, reinstallCurrent: true)

        #expect(!switched)
        #expect(model.lastResult.contains("reauth-preflight-stop"))
        #expect(model.settings.automationPausedReason != nil)
        #expect(try SecureFiles.read(f.clientURL) == f.credentialA.primary)
        #expect(try f.store.loadCredential(f.a.id, vault: f.vault).primary == refreshed.primary)
    }
}
