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
    func testModelPoolsMatchCursorSettingsInsteadOfTheTotal() throws {
        // Real Ultra response: Cursor's Plan & Usage page shows "Cursor Models 0% used"
        // and "Other Models 54% used"; the 1.76% total appears nowhere in its UI.
        let reading = try parse(#"{"billingCycleEnd":"2030-11-12T09:09:56.000Z","individualUsage":{"plan":{"enabled":true,"used":5464,"limit":40000,"remaining":34536,"autoPercentUsed":0,"apiPercentUsed":54.64,"totalPercentUsed":1.7625806451612904},"onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}}}"#)
        XCTAssertEqual(reading.windows.map(\.name), ["Cursor models", "Other models"])
        XCTAssertEqual(reading.windows.map(\.usedPercent), [0, 54.64])
        XCTAssertEqual(reading.remainingPercent ?? 0, 45.36, accuracy: 0.001)
        XCTAssertTrue(reading.windows.allSatisfy { $0.resetsAt != nil })
    }
    func testPoolPastItsAllowanceReadsAsExhausted() throws {
        let reading = try parse(#"{"individualUsage":{"plan":{"enabled":true,"autoPercentUsed":12,"apiPercentUsed":130,"totalPercentUsed":40}}}"#)
        XCTAssertEqual(reading.windows.map(\.usedPercent), [12, 100])
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
