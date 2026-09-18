import XCTest
@testable import SubscriptionCore

final class ResetCountdownTests: XCTestCase {
    func testDaysHoursMinutesAndSubMinuteBoundary() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ResetCountdown.text(until: now.addingTimeInterval(3 * 86400 + 5 * 3600 + 12 * 60), now: now, language: .ru), "через 3 д 5 ч 12 мин")
        XCTAssertEqual(ResetCountdown.text(until: now.addingTimeInterval(3660), now: now, language: .en), "in 1h 1m")
        XCTAssertEqual(ResetCountdown.text(until: now.addingTimeInterval(3660), now: now, language: .ru, compact: true), "1ч 1мин")
        XCTAssertEqual(ResetCountdown.text(until: now.addingTimeInterval(59), now: now, language: .en, compact: true), "<1m")
        XCTAssertEqual(ResetCountdown.text(until: now.addingTimeInterval(59), now: now, language: .ru), "менее минуты")
        XCTAssertEqual(ResetCountdown.text(until: now.addingTimeInterval(60), now: now, language: .en), "in 1m")
        XCTAssertEqual(ResetCountdown.text(until: now, now: now, language: .ru), "ожидаем сброс")
        XCTAssertEqual(ResetCountdown.text(until: now.addingTimeInterval(-60), now: now, language: .en), "reset pending")
    }
}
