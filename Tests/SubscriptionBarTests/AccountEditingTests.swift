import Testing
import Foundation
import SubscriptionCore
@testable import SubscriptionBar

@MainActor
struct AccountEditingTests {
    @Test func renameTrimsAndRejectsEmptyOrOverlongNames() throws {
        let model = AppModel(demo: true)
        let id = try #require(model.settings.active[.claude])
        let original = try #require(model.settings.accounts.first { $0.id == id }).label

        model.rename(id, to: "  Work laptop  ")
        #expect(model.settings.accounts.first { $0.id == id }?.label == "Work laptop")

        model.rename(id, to: "   ")
        #expect(model.settings.accounts.first { $0.id == id }?.label == "Work laptop")

        model.rename(id, to: String(repeating: "x", count: 81))
        #expect(model.settings.accounts.first { $0.id == id }?.label == "Work laptop")
        #expect(original != "Work laptop")
    }

    @Test func deletingTheActiveAccountPromotesAnotherOneOfTheSameService() async throws {
        let model = AppModel(demo: true)
        let active = try #require(model.settings.active[.codex])
        let spare = try #require(model.settings.accounts.first { $0.provider == .codex && $0.id != active })

        await model.delete(active)
        #expect(model.settings.accounts.contains { $0.id == active } == false)
        #expect(model.settings.active[.codex] == spare.id)
        #expect(model.readings[active] == nil)

        await model.delete(spare.id)
        #expect(model.settings.active[.codex] == nil)
        #expect(model.settings.accounts.contains { $0.provider == .codex } == false)
    }

    @Test func criticalRemainingRaisesTheMenuBarAlert() throws {
        let model = AppModel(demo: true)
        let id = try #require(model.settings.active[.claude])
        model.errors = [:]
        model.settings.automationPausedReason = nil

        model.publishReading(try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 10)], source: "test"), for: id)
        #expect(model.menuBarEntries.first { $0.provider == .claude }?.level == .ok)

        model.publishReading(try UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 99.5)], source: "test"), for: id)
        #expect(model.menuBarEntries.first { $0.provider == .claude }?.level == .critical)
        #expect(model.needsAttention)
    }

    @Test func thresholdsStayOrderedWhenEdited() {
        let model = AppModel(demo: true)
        model.setSwitchThreshold(30)
        #expect(model.settings.switchAt == 30)
        #expect(model.settings.warnAt == 30)
        model.setWarnThreshold(5)
        #expect(model.settings.warnAt == 30)
        model.setSwitchThreshold(2)
        model.setWarnThreshold(20)
        #expect(model.settings.warnAt == 20)
    }
}
