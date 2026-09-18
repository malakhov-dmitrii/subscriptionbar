import XCTest
@testable import SubscriptionCore

final class ClaudeFableTests: XCTestCase {
    private func parse(_ json: String) throws -> UsageSnapshot {
        try UsageAPI.parse(provider: .claude, data: Data(json.utf8), source: "fixture")
    }
    func testLegacyFableAndReset() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":10},"seven_day_fable":{"utilization":99,"resets_at":"2030-01-01T00:00:00Z"}}"#)
        XCTAssertEqual(snapshot.remainingPercent, 1)
        XCTAssertEqual(snapshot.windows.last?.name, "Fable · 7 days")
        XCTAssertNotNil(snapshot.windows.last?.resetsAt)
    }
    func testScopedOverridesLegacyWithoutDuplicate() throws {
        let snapshot = try parse(#"{"seven_day_fable":{"utilization":100},"limits":[{"kind":"weekly_scoped","percent":73,"scope":{"model":{"id":null,"display_name":"Fable"}}}]}"#)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.remainingPercent, 27)
    }
    func testModelIDAndNullLegacy() throws {
        let snapshot = try parse(#"{"seven_day_fable":null,"limits":[{"kind":"weekly_scoped","percent":99,"scope":{"model":{"id":"claude-fable-1","display_name":"New name"}}}]}"#)
        XCTAssertEqual(snapshot.remainingPercent, 1)
    }
    func testInvalidFableIsNotIgnored() {
        XCTAssertThrowsError(try parse(#"{"five_hour":{"utilization":1},"limits":[{"kind":"weekly_scoped","percent":101,"scope":{"model":{"display_name":"Fable"}}}]}"#))
    }
    func testMissingFableDoesNotInventQuota() throws {
        let snapshot = try parse(#"{"five_hour":{"utilization":10},"seven_day_fable":null}"#)
        XCTAssertEqual(snapshot.windows.count, 1)
    }
    func testRotationRequiresConfirmedFableOnTarget() throws {
        var settings = Settings()
        let a = Account(provider: .claude, label: "A", identity: "a")
        let b = Account(provider: .claude, label: "B", identity: "b")
        settings.accounts = [a, b]
        settings.active[.claude] = a.id
        let now = Date()
        let active = try parse(#"{"five_hour":{"utilization":5},"seven_day_fable":{"utilization":99}}"#)
        let unknown = try parse(#"{"five_hour":{"utilization":5}}"#)
        if case .switchTo = RotationPolicy.decide(provider: .claude, settings: settings, readings: [a.id: active, b.id: unknown], now: now.addingTimeInterval(1)) { XCTFail("Fable target quota was not confirmed") }
        let available = try parse(#"{"five_hour":{"utilization":5},"seven_day_fable":{"utilization":10}}"#)
        XCTAssertEqual(RotationPolicy.decide(provider: .claude, settings: settings, readings: [a.id: active, b.id: available], now: now.addingTimeInterval(1)), .switchTo(b.id))
    }
}
