import XCTest
@testable import SubscriptionCore

final class CursorUsageTests: XCTestCase {
    private func parse(_ fields: String) throws -> UsageSnapshot {
        try UsageAPI.parse(provider: .cursor, data: Data(fields.utf8), source: "fixture")
    }
    func testPersonalPlanAndResetFromRealResponseShape() throws {
        let reading = try parse(#"{"billingCycleEnd":"2030-10-12T09:09:56.000Z","individualUsage":{"plan":{"enabled":true,"used":0,"limit":40000,"remaining":40000,"totalPercentUsed":0},"onDemand":{"enabled":false,"used":0,"limit":null}}}"#)
        XCTAssertEqual(reading.remainingPercent, 100)
        XCTAssertEqual(reading.windows.count, 1)
        XCTAssertNotNil(reading.windows[0].resetsAt)
    }
    func testPercentIsNotRatioAndDoesNotAverageCategories() throws {
        let reading = try parse(#"{"individualUsage":{"plan":{"enabled":true,"totalPercentUsed":0.36,"autoPercentUsed":70,"apiPercentUsed":90}}}"#)
        XCTAssertEqual(reading.windows[0].usedPercent, 0.36)
    }
    func testCountsAndPersonalCapHaveSeparateWindows() throws {
        let reading = try parse(#"{"individualUsage":{"plan":{"limit":2000,"used":500},"overall":{"limit":1000,"remaining":200}}}"#)
        XCTAssertEqual(reading.windows.count, 2)
        XCTAssertEqual(reading.windows[0].remaining, 75)
        XCTAssertEqual(reading.windows[1].remaining, 20, accuracy: 0.001)
    }
    func testUnknownAndSharedQuotasAreNotPersonalAvailability() {
        for value in [#"{}"#, #"{"individualUsage":{"plan":{"enabled":true}}}"#, #"{"individualUsage":{},"teamUsage":{"pooled":{"used":0,"limit":1000}}}"#, #"{"individualUsage":{"plan":{"totalPercentUsed":101}}}"#] {
            XCTAssertThrowsError(try parse(value))
        }
    }
    func testCursorRequestUsesValidatedCookieAndStableAccountIdentity() throws {
        let payload = Data(#"{"sub":"auth0|user_fixture"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"
        let request = try UsageAPI.request(UsageCredential(provider: .cursor, bearer: token))
        XCTAssertEqual(request.url?.absoluteString, "https://cursor.com/api/usage-summary")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=user_fixture%3A%3A\(token)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(try CredentialParser.parse(provider: .cursor, data: Data(token.utf8)).identity, "auth0|user_fixture")
        XCTAssertThrowsError(try CursorLocalAuth.cookieHeader(token + "; extra=1"))
        XCTAssertFalse(Account(provider: .cursor, label: "test", identity: "test").canSwitch)
        XCTAssertFalse(Account(provider: .kimiCode, label: "test", identity: "test").canSwitch)
    }
}
