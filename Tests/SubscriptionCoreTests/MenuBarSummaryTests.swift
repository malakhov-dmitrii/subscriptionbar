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

    func testSessionAndWeeklyLimitsKeepFixedLabelledRows() throws {
        L10n.language = .en
        let now = Date()
        let usage = try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 58.4), UsageWindow("7 days", usedPercent: 22),
                                                UsageWindow("Fable · 7 days", usedPercent: 99)], source: "test", fetchedAt: now)
        XCTAssertEqual(MenuBarSummary.rows(usage, failed: false, now: now).map(\.text), ["5h 41%", "wk 78%"])
        XCTAssertEqual(MenuBarSummary.rows(usage, failed: false, now: now).map(\.spokenWindow), ["5 hours", "7 days"])

        // Right after a session reset the weekly limit is the lower one; the rows must not swap.
        let reset = try UsageSnapshot(windows: [UsageWindow("Weekly", usedPercent: 90), UsageWindow("5 hours", usedPercent: 0)],
                                      source: "test", fetchedAt: now)
        XCTAssertEqual(MenuBarSummary.rows(reset, failed: false, now: now).map(\.text), ["5h 100%", "wk 10%"])

        XCTAssertEqual(MenuBarSummary.rows(usage, failed: true, now: now).map(\.text), ["5h —", "wk —"])
        XCTAssertEqual(MenuBarSummary.rows(usage, failed: false, now: now.addingTimeInterval(91)).map(\.text), ["5h —", "wk —"])
    }

    func testServicesWithoutSessionAndWeeklyPairKeepOneValue() throws {
        let now = Date()
        let session = try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 10)], source: "test", fetchedAt: now)
        let codex = try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 10), UsageWindow("Weekly", usedPercent: 50)],
                                      source: "test", fetchedAt: now)
        XCTAssertTrue(MenuBarSummary.rows(session, failed: false, now: now).isEmpty)
        XCTAssertTrue(MenuBarSummary.rows(codex, failed: false, now: now).isEmpty)
        XCTAssertTrue(MenuBarSummary.rows(nil, failed: false, now: now).isEmpty)
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
