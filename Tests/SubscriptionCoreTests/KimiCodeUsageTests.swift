import XCTest
@testable import SubscriptionCore

final class KimiCodeUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_732_800)
    private func parse(_ json: String) throws -> UsageSnapshot {
        try KimiCodeUsage.parse(data: Data(json.utf8), source: "fixture", now: now)
    }

    func testOfficialCountsAndWindowPreserveReset() throws {
        let result = try parse(#"{"usage":{"limit":"1000","remaining":"700","resetTime":"2026-09-25T12:00:00Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":20,"resetTime":"2026-09-18T17:00:00.123Z"}}]}"#)
        XCTAssertEqual(result.windows.map(\.name), ["Weekly", "5 hours"])
        XCTAssertEqual(result.windows.map(\.usedPercent), [30, 20])
        XCTAssertTrue(result.windows.allSatisfy { $0.resetsAt != nil })
        XCTAssertEqual(result.fetchedAt, now)
    }

    func testRatioPoolsReplaceLegacyAndUseFractionUnits() throws {
        let result = try parse(#"{"usage":{"limit":100,"used":90},"usages":{"limit_5h":{"used_ratio":0.36,"reset_time":"2026-09-25T12:00:00Z"},"limit_7d":{"used_ratio":0},"limit_month_total":{"used_ratio":1}}}"#)
        XCTAssertEqual(result.windows.map(\.name), ["5 hours", "Weekly", "Monthly"])
        XCTAssertEqual(result.windows.map(\.usedPercent), [36, 0, 100])
        XCTAssertNotNil(result.windows[0].resetsAt)
    }

    func testCountBoundariesAndPartialFields() throws {
        for detail in [#"{"limit":100,"used":0}"#, #"{"limit":"100","remaining":"100"}"#] {
            XCTAssertEqual(try parse("{\"usage\":\(detail)}").remainingPercent, 100)
        }
        XCTAssertEqual(try parse(#"{"usage":{"limit":100,"used":100,"remaining":0}}"#).remainingPercent, 0)
        let onlyWindow = try parse(#"{"limits":[{"window":{"duration":2,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":10,"remaining":5}}]}"#)
        XCTAssertEqual(onlyWindow.windows[0].name, "2 hours")
    }

    func testMalformedOrMissingQuotaNeverInventsZero() {
        for json in [
            #"{}"#, #"[]"#, #"{"usage":{"limit":100}}"#,
            #"{"usage":{"limit":0,"used":0}}"#,
            #"{"usage":{"limit":100,"used":null,"remaining":100}}"#,
            #"{"usage":{"limit":100,"used":101}}"#,
            #"{"usage":{"limit":100,"used":-1}}"#,
            #"{"usage":{"limit":100,"used":20,"remaining":90}}"#,
            #"{"usage":{"limit":100,"used":0,"resetTime":"bad"}}"#,
            #"{"usages":{"limit_5h":{"used_ratio":36}}}"#,
            #"{"usages":{"limit_5h":{"used_ratio":-0.1}}}"#,
            #"{"usages":{"limit_5h":{}}}"#,
            #"{"usages":{},"usage":{"limit":100,"used":0}}"#,
            #"{"limits":[{"window":{"duration":0,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":100,"used":0}}]}"#
        ] { XCTAssertThrowsError(try parse(json), json) }
    }

    func testNullRepresentationsRequireAnotherValidQuota() throws {
        XCTAssertEqual(try parse(#"{"usages":null,"usage":{"limit":100,"used":20},"limits":null}"#).remainingPercent, 80)
        let result = try parse(#"{"usage":null,"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":100,"used":0}}]}"#)
        XCTAssertEqual(result.windows[0].name, "5 hours")
        XCTAssertEqual(result.remainingPercent, 100)
        XCTAssertThrowsError(try parse(#"{"usages":null,"usage":null,"limits":null}"#))
    }
}
