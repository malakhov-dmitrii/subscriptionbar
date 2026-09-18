import XCTest
@testable import SubscriptionCore

final class MenuBarSummaryTests: XCTestCase {
    func testRemainingUsesTightestWindowWithoutRoundingUp() throws {
        let now = Date()
        let usage = try UsageSnapshot(windows: [UsageWindow("5h", usedPercent: 20), UsageWindow("week", usedPercent: 98.6)], source: "test", fetchedAt: now)
        XCTAssertEqual(MenuBarSummary.value(usage, failed: false, now: now), "1%")
        XCTAssertEqual(MenuBarSummary.value(usage, failed: true, now: now), "—")
        XCTAssertEqual(MenuBarSummary.value(usage, failed: false, now: now.addingTimeInterval(91)), "—")
        XCTAssertEqual(MenuBarSummary.value(nil, failed: false, now: now), "—")
    }

    func testBalanceRetainsCurrencies() throws {
        let now = Date()
        let usage = try UsageSnapshot(balances: [Balance(currency: "USD", available: 8.3), Balance(currency: "CNY", available: 12)], source: "test", fetchedAt: now)
        XCTAssertEqual(MenuBarSummary.value(usage, failed: false, now: now), "$8.30/¥12.00")
    }

    func testOldSettingsDecodeWithoutMenuBarSelection() throws {
        let data = try JSONEncoder().encode(Settings())
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertNil(decoded.menuBarProviders)
    }
}
