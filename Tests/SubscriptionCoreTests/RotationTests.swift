import XCTest
@testable import SubscriptionCore

final class RotationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func state() -> Settings {
        var s = Settings()
        s.accounts = [Account(provider: .codex, label: "A", identity: "a"), Account(provider: .codex, label: "B", identity: "b")]
        s.active[.codex] = s.accounts[0].id
        return s
    }
    func reading(_ used: Double, age: Double = 0, reset: Double = 1000) throws -> UsageSnapshot {
        try UsageSnapshot(windows: [UsageWindow("5h", usedPercent: used, resetsAt: now.addingTimeInterval(reset))],
                          source: "fixture", fetchedAt: now.addingTimeInterval(-age))
    }
    func testOnePercentBoundaryAndTarget() throws {
        let s = state(); let a = s.accounts[0].id; let b = s.accounts[1].id
        XCTAssertEqual(RotationPolicy.decide(provider: .codex, settings: s, readings: [a: try reading(99), b: try reading(20)], now: now), .switchTo(b))
        XCTAssertEqual(RotationPolicy.decide(provider: .codex, settings: s, readings: [a: try reading(98.999), b: try reading(20)], now: now), .stay)
    }
    func testStaleFailedAndPastResetCannotTrigger() throws {
        let s = state(); let a = s.accounts[0].id; let b = s.accounts[1].id
        for r in [try reading(100, age: 91), try reading(100, reset: -1)] {
            XCTAssertEqual(RotationPolicy.decide(provider: .codex, settings: s, readings: [a: r, b: try reading(1)], now: now), .stay)
        }
        XCTAssertEqual(RotationPolicy.decide(provider: .codex, settings: s, readings: [a: try reading(100), b: try reading(1)], failures: [a], now: now), .stay)
    }
    func testExhaustedOrUnknownTargetNeverSelected() throws {
        let s = state(); let a = s.accounts[0].id; let b = s.accounts[1].id
        for entries in [[a: try reading(99)], [a: try reading(99), b: try reading(99)], [a: try reading(99), b: try reading(2, age: 91)]] {
            guard case .unavailable = RotationPolicy.decide(provider: .codex, settings: s, readings: entries, now: now) else { return XCTFail("Unsafe target") }
        }
    }
    func testPauseAndCooldown() throws {
        var s = state(); let r = [s.accounts[0].id: try reading(100), s.accounts[1].id: try reading(0)]
        s.lastSwitch[.codex] = now.addingTimeInterval(-30)
        XCTAssertEqual(RotationPolicy.decide(provider: .codex, settings: s, readings: r, now: now), .stay)
        s.lastSwitch = [:]; s.automationPausedReason = "Write interrupted"
        XCTAssertEqual(RotationPolicy.decide(provider: .codex, settings: s, readings: r, now: now), .stay)
    }
    func testRejectsMalformedPercent() throws {
        for v in [Double.nan, .infinity, -1, 101] { XCTAssertThrowsError(try UsageWindow("test", usedPercent: v)) }
        XCTAssertThrowsError(try UsageSnapshot(source: "test"))
    }
    func testDistinctCurrencyBalancesNotSummed() throws {
        let a = Account(provider: .deepSeek, label: "D", identity: "d")
        let r = try UsageSnapshot(balances: [Balance(currency: "USD", available: 0), Balance(currency: "CNY", available: 10)], source: "fixture")
        XCTAssertFalse(RotationPolicy.exhausted(r, account: a))
    }
}
