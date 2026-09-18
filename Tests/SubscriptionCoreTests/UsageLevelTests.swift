import XCTest
@testable import SubscriptionCore

final class UsageLevelTests: XCTestCase {
    func testThresholdsAreOrderedAndInclusive() {
        XCTAssertEqual(UsageLevel.of(remaining: 0.5, stale: false, warnAt: 15, criticalAt: 1), .critical)
        XCTAssertEqual(UsageLevel.of(remaining: 1, stale: false, warnAt: 15, criticalAt: 1), .critical)
        XCTAssertEqual(UsageLevel.of(remaining: 15, stale: false, warnAt: 15, criticalAt: 1), .warning)
        XCTAssertEqual(UsageLevel.of(remaining: 15.1, stale: false, warnAt: 15, criticalAt: 1), .ok)
        XCTAssertEqual(UsageLevel.of(remaining: 0, stale: true, warnAt: 15, criticalAt: 1), .stale)
        XCTAssertEqual(UsageLevel.of(remaining: nil, stale: false, warnAt: 15, criticalAt: 1), .ok)
    }

    func testWarnNeverSitsBelowSwitch() {
        var settings = Settings()
        XCTAssertEqual(settings.switchAt, 1)
        XCTAssertEqual(settings.warnAt, 15)
        settings.switchThreshold = 25
        settings.warnThreshold = 5
        XCTAssertEqual(settings.warnAt, 25, "a warning after the switch already happened is useless")
        XCTAssertEqual(settings.level(24, stale: false), .critical)
    }

    func testRotationUsesTheConfiguredThreshold() throws {
        var settings = Settings()
        settings.switchThreshold = 10
        let low = try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 92)], source: "test")
        let account = Account(provider: .claude, label: "a", identity: "a")
        XCTAssertTrue(RotationPolicy.exhausted(low, account: account, threshold: settings.switchAt))
        XCTAssertFalse(RotationPolicy.exhausted(low, account: account), "the default stays at 1%")
    }

    func testMenuBarLevelMarksExhaustedBalanceCritical() throws {
        let now = Date()
        var settings = Settings()
        settings.accounts = [Account(provider: .openRouter, label: "a", identity: "a", balanceThreshold: 5)]
        let empty = try UsageSnapshot(balances: [Balance(currency: "USD", available: 2)], source: "test", fetchedAt: now)
        let funded = try UsageSnapshot(balances: [Balance(currency: "USD", available: 40)], source: "test", fetchedAt: now)
        XCTAssertEqual(MenuBarSummary.level(empty, failed: false, account: settings.accounts[0], settings: settings, now: now), .critical)
        XCTAssertEqual(MenuBarSummary.level(funded, failed: false, account: settings.accounts[0], settings: settings, now: now), .ok)
        XCTAssertEqual(MenuBarSummary.level(funded, failed: true, account: settings.accounts[0], settings: settings, now: now), .stale)
        XCTAssertEqual(MenuBarSummary.level(funded, failed: false, account: settings.accounts[0], settings: settings,
                                            now: now.addingTimeInterval(120)), .stale)
    }

    func testSettingsWithoutThresholdsStillDecode() throws {
        // Build a file the way an older build wrote it: everything except the new keys.
        var fresh = Settings()
        fresh.switchThreshold = 9
        fresh.warnThreshold = 9
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        fields.removeValue(forKey: "switchThreshold")
        fields.removeValue(forKey: "warnThreshold")
        let legacy = try JSONSerialization.data(withJSONObject: fields)
        let decoded = try JSONDecoder().decode(Settings.self, from: legacy)
        XCTAssertNil(decoded.switchThreshold)
        XCTAssertEqual(decoded.switchAt, 1)
        XCTAssertEqual(decoded.warnAt, 15)
    }
}
