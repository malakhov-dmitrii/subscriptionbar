import Testing
import AppKit
import Foundation
import SubscriptionCore
@testable import SubscriptionBar

@MainActor
struct MenuBarLabelTests {
    @Test func claudeShowsSessionAboveWeekWithLabels() throws {
        let model = AppModel(demo: true)
        // AppModel adopts the saved or system language; the expectations below are English.
        L10n.language = .en
        let id = try #require(model.settings.active[.claude])
        model.errors = [:]
        model.publishReading(try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 58), UsageWindow("7 days", usedPercent: 22)],
                                               source: "test"), for: id)

        let entry = try #require(model.menuBarEntries.first { $0.provider == .claude })
        #expect(entry.rows.map(\.text) == ["5h 42%", "wk 78%"])
        #expect(entry.text == "C 5h 42% wk 78%")
        #expect(model.menuBarAccessibilitySummary.contains("Claude 5 hours 42% remaining, 7 days 78% remaining"))
    }

    @Test func stackedLabelFitsTheMenuBarAsATemplate() throws {
        let rows = [MenuBarRow(window: "5h", spokenWindow: "5 hours", value: "100%"),
                    MenuBarRow(window: "wk", spokenWindow: "7 days", value: "100%")]
        let entries = [MenuBarEntry(provider: .claude, label: "C", value: "100%", rows: rows, level: .critical),
                       MenuBarEntry(provider: .codex, label: "X", value: "55%", level: .ok)]
        let image = try #require(MenuBarLabel(entries: entries, needsAttention: true).templateImage(scale: 2))
        #expect(image.isTemplate)
        #expect(image.size.height <= MenuBarLabel.height)
        #expect(image.size.width > 0)
    }
}
