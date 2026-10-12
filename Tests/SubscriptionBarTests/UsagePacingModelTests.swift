import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor struct UsagePacingModelTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func next(_ key: String) -> Int { lock.withLock { counts[key, default: 0] += 1; return counts[key]! } }
        func count(_ key: String) -> Int { lock.withLock { counts[key, default: 0] } }
    }

    @Test func rateLimitedAccountKeepsItsNumbersAndIsNotPolledEarly() async throws {
        let f = try CodexMonitoringTests.Fixture(); defer { f.clean() }
        try SecureFiles.write(f.credentialA.primary, to: f.clientURL, expected: nil)
        let calls = Calls()
        let runtime = AccountRuntime(store: f.store, vault: f.vault, fetchUsage: { request in
            let subject = CredentialParser.jwt(request.bearer)?["sub"]?.string ?? "?"
            if subject == "A", calls.next("A") == 2 { throw AppFailure.rateLimited(.codex, retryAfter: nil) }
            if subject == "B" { _ = calls.next("B") }
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: subject == "A" ? 13 : 27)], source: "fixture")
        })
        let model = AppModel(demo: false, store: f.store, runtime: runtime, startPolling: false, notificationSender: { _ in })
        model.credentialAccess = .ready
        func codexEntry() -> MenuBarEntry? { model.menuBarEntries.first { $0.provider == .codex } }

        await model.refresh()
        #expect(codexEntry()?.value == "87%")

        await model.refresh()
        #expect(calls.count("A") == 2)
        #expect(model.errors[f.a.id] == nil)
        #expect(!model.needsAttention)

        model.now = Date().addingTimeInterval(180)
        #expect(codexEntry()?.value == "87%")
        #expect(codexEntry()?.delayed == false)
        model.now = Date().addingTimeInterval(600)
        #expect(codexEntry()?.value == "87%")
        #expect(codexEntry()?.delayed == true)
        let remaining: String = model.t("%@ remaining", "87%")
        let delayed: String = model.t("data is delayed")
        #expect(model.menuBarAccessibilitySummary.contains("\(remaining), \(delayed)"))

        await model.refresh()
        #expect(calls.count("A") == 2)
        #expect(calls.count("B") == 3)
    }
}
