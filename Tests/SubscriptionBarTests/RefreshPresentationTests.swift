import Testing
import Foundation
import SubscriptionCore
@testable import SubscriptionBar

@MainActor
struct RefreshPresentationTests {
    @Test func successfulRefreshDoesNotTemporarilyShowStaleWarning() throws {
        let model = AppModel(demo: true)
        let id = try #require(model.settings.active[.claude])
        model.now = Date().addingTimeInterval(-30)
        let reading = try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 10)], source: "fixture")
        model.publishReading(reading, for: id)
        #expect(model.readings[id]?.isFresh(at: model.now) == true)
        #expect(model.menuBarText.contains("C90%"))
    }
}
