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

    @Test func balanceThresholdShowsTheCurrencyTheServiceActuallyReported() throws {
        let model = AppModel(demo: true)
        let openRouter = try #require(model.settings.accounts.first { $0.provider == .openRouter })
        #expect(model.balanceCurrency(openRouter) == "USD")

        model.readings[openRouter.id] = try UsageSnapshot(
            balances: [Balance(currency: "CNY", available: 12)], source: "test")
        #expect(model.balanceCurrency(openRouter) == "CNY")

        // No reading yet must still label the field rather than leave a bare number.
        model.readings[openRouter.id] = nil
        #expect(model.balanceCurrency(openRouter) == "USD")
    }

    @Test func cliFolderCheckAcceptsOnlyAnExistingDirectory() throws {
        let model = AppModel(demo: true)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("subscriptionbar-path-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-folder")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        #expect(model.pathExists(directory.path))
        #expect(model.pathExists("  " + directory.path + "  "), "a pasted path with spaces still resolves")
        #expect(model.pathExists("~"), "tilde is expanded")
        #expect(model.pathExists(file.path) == false, "a file is not a config folder")
        #expect(model.pathExists(directory.path + "/missing") == false)
        #expect(model.pathExists("") == false)
    }
}
