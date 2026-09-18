import XCTest
@testable import SubscriptionCore

final class GrokQuotaTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_789_732_800)
    func parse(_ fields: String) throws -> UsageSnapshot {
        try UsageAPI.parse(provider: .grok, data: Data("{\(fields)}".utf8), source: "fixture", now: now)
    }
    let period = #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-17T12:50:31.988010+00:00","end":"2026-09-24T12:50:31.988010+00:00"}"#
    func testProtoOmittedZeroWithCurrentWeeklyPeriod() throws {
        let snapshot = try parse(period + #", "onDemandUsed":{"val":0},"onDemandCap":{"val":0}"#)
        XCTAssertEqual(snapshot.remainingPercent, 100)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
    }
    func testExplicitPercentStillWins() throws {
        XCTAssertEqual(try parse(period + #", "creditUsagePercent":42"#).remainingPercent, 58)
    }
    func testMissingOrInvalidPercentCannotInventQuota() {
        for json in [#""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"}"#, period + #", "creditUsagePercent":null"#, period + #", "creditUsagePercent":"bad""#, #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2020-01-01T00:00:00Z","end":"2020-01-08T00:00:00Z"}"#] {
            XCTAssertThrowsError(try parse(json))
        }
    }
}
