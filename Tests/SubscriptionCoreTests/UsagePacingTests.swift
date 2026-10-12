import XCTest
@testable import SubscriptionCore

final class UsagePacingTests: XCTestCase {
    func testTooManyRequestsBecomesARateLimitWithTheServerDelay() {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        let oauth = UsageCredential(provider: .claude, bearer: "token")
        XCTAssertEqual(UsageAPI.rejection(response(429, ["Retry-After": "120"]), credential: oauth, now: now),
                       .rateLimited(.claude, retryAfter: 120))
        XCTAssertEqual(UsageAPI.rejection(response(429, ["Retry-After": "Fri, 15 Jan 2027 08:02:00 GMT"]), credential: oauth, now: now),
                       .rateLimited(.claude, retryAfter: 120))
        XCTAssertEqual(UsageAPI.rejection(response(429), credential: oauth, now: now), .rateLimited(.claude, retryAfter: nil))
        XCTAssertEqual(UsageAPI.rejection(response(401), credential: oauth, now: now),
                       .message("Claude OAuth usage is unavailable. Connect a Claude browser session to read limits."))
        XCTAssertEqual(UsageAPI.rejection(response(500), credential: UsageCredential(provider: .codex, bearer: "token"), now: now),
                       .message("ChatGPT / Codex: usage service rejected the request. Check account access."))
    }

    func testPacingBacksOffOnRefusalAndRelaxesAfterSuccess() {
        let now = Date()
        let first = UsagePacing.refused(nil, retryAfter: nil, now: now)
        XCTAssertEqual(first.interval, 120)
        XCTAssertFalse(first.allowsFetch(at: now.addingTimeInterval(119)))
        XCTAssertTrue(first.allowsFetch(at: now.addingTimeInterval(120)))
        XCTAssertEqual(UsagePacing.refused(first, retryAfter: nil, now: now).interval, 240)
        XCTAssertEqual(UsagePacing.refused(first, retryAfter: 600, now: now).interval, 600)
        XCTAssertEqual(UsagePacing.refused(nil, retryAfter: 7200, now: now).interval, 3600)
        var repeated: UsagePacing?
        for _ in 0..<10 { repeated = UsagePacing.refused(repeated, retryAfter: nil, now: now) }
        XCTAssertEqual(repeated?.interval, 900)

        let relaxed = UsagePacing.succeeded(first, now: now)
        XCTAssertEqual(relaxed?.interval, 60)
        XCTAssertEqual(relaxed?.allowsFetch(at: now.addingTimeInterval(59)), false)
        XCTAssertNil(UsagePacing.succeeded(relaxed, now: now))
        XCTAssertNil(UsagePacing.succeeded(nil, now: now))
    }

    func testPacedReadingStaysVisibleThenDimsThenExpires() throws {
        L10n.language = .en
        let fetched = Date()
        let reading = try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 40, resetsAt: fetched.addingTimeInterval(3 * 3600)),
                                                  UsageWindow("7 days", usedPercent: 10, resetsAt: fetched.addingTimeInterval(86_400))],
                                        source: "test", fetchedAt: fetched)
        func state(after seconds: TimeInterval, paced: Bool = true, failed: Bool = false) -> ReadingState {
            ReadingFreshness.state(reading, failed: failed, paced: paced, now: fetched.addingTimeInterval(seconds))
        }
        XCTAssertEqual(state(after: 30, paced: false), .current)
        XCTAssertEqual(state(after: 180, paced: false), .unavailable)
        XCTAssertEqual(state(after: 180), .current)
        XCTAssertEqual(state(after: 600), .delayed)
        XCTAssertEqual(state(after: 2000), .unavailable)
        XCTAssertEqual(state(after: 30, failed: true), .unavailable)
        XCTAssertEqual(ReadingFreshness.state(nil, failed: false, paced: true, now: fetched), .unavailable)

        let reset = try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 40, resetsAt: fetched.addingTimeInterval(100))],
                                      source: "test", fetchedAt: fetched)
        XCTAssertEqual(ReadingFreshness.state(reset, failed: false, paced: true, now: fetched.addingTimeInterval(180)), .unavailable)

        let delayed = fetched.addingTimeInterval(600)
        XCTAssertEqual(MenuBarSummary.value(reading, failed: false, paced: true, now: delayed), "60%")
        XCTAssertEqual(MenuBarSummary.rows(reading, failed: false, paced: true, now: delayed).map(\.text), ["5h 60%", "wk 90%"])
        XCTAssertEqual(MenuBarSummary.value(reading, failed: false, now: delayed), "—")
    }
}
