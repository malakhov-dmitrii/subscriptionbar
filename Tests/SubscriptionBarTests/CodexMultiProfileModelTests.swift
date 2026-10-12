import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor
struct CodexMultiProfileModelTests {
    private func configure(_ fixture: inout CodexMonitoringTests.Fixture) throws -> [CodexClientProfile] {
        let profiles = [
            CodexClientProfile(name: "Work", home: fixture.root.appendingPathComponent("work").path,
                               applicationPath: "/Applications/Codex.app"),
            CodexClientProfile(name: "Personal", home: fixture.root.appendingPathComponent("personal").path,
                               applicationPath: "/Applications/codex2.app")
        ]
        fixture.settings.codexClientProfiles = profiles
        fixture.settings.selectedCodexClientID = profiles[0].id
        let expected = try SecureFiles.read(fixture.store.settingsURL)
        _ = try fixture.store.saveSettings(fixture.settings, expected: expected)
        return profiles
    }

    private func write(_ credential: CredentialEnvelope, profile: CodexClientProfile) throws {
        let url = URL(fileURLWithPath: profile.home).appendingPathComponent("auth.json")
        try SecureFiles.write(credential.primary, to: url, expected: SecureFiles.read(url))
    }

    private func model(_ fixture: CodexMonitoringTests.Fixture) throws -> AppModel {
        let a = try #require(try JSONValue.parse(fixture.credentialA.primary)["tokens"]?["access_token"]?.string)
        let b = try #require(try JSONValue.parse(fixture.credentialB.primary)["tokens"]?["access_token"]?.string)
        let runtime = AccountRuntime(store: fixture.store, vault: fixture.vault, fetchUsage: { request in
            #expect(request.provider == .codex)
            #expect(request.bearer == a || request.bearer == b)
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: request.bearer == a ? 13 : 27)], source: "fixture")
        })
        let model = AppModel(demo: false, store: fixture.store, runtime: runtime, startPolling: false)
        model.credentialAccess = .ready
        return model
    }

    private func expectBothQuotas(_ model: AppModel, fixture: CodexMonitoringTests.Fixture) {
        #expect(model.readings[fixture.a.id]?.remainingPercent == 87)
        #expect(model.readings[fixture.b.id]?.remainingPercent == 73)
        #expect(model.errors[fixture.a.id] == nil)
        #expect(model.errors[fixture.b.id] == nil)
    }

    @Test func externalAccountChangeMovesSelectedMarkerAndKeepsBothSavedQuotas() async throws {
        var fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        let profiles = try configure(&fixture)
        try write(fixture.credentialB, profile: profiles[0])
        let model = try model(fixture)
        await model.refresh()
        expectBothQuotas(model, fixture: fixture)
        #expect(model.settings.active[.codex] == fixture.b.id)
        #expect(model.codexObservations[profiles[0].id]?.accountID == fixture.b.id)
        #expect(model.codexObservations[profiles[0].id]?.issue == nil)
        #expect(try fixture.store.loadCredential(fixture.a.id, vault: fixture.vault) == fixture.credentialA)
        #expect(try fixture.store.loadCredential(fixture.b.id, vault: fixture.vault) == fixture.credentialB)
    }

    @Test func signedOutSelectedHomeClearsMarkerWithoutSuppressingSavedQuotas() async throws {
        var fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        let profiles = try configure(&fixture)
        try write(fixture.credentialB, profile: profiles[1])
        let model = try model(fixture)
        await model.refresh()
        expectBothQuotas(model, fixture: fixture)
        #expect(model.settings.active[.codex] == nil)
        #expect(model.codexObservations[profiles[0].id]?.accountID == nil)
        #expect(model.codexObservations[profiles[0].id]?.issue != nil)
        #expect(model.codexObservations[profiles[1].id]?.accountID == fixture.b.id)
        #expect(model.codexObservations[profiles[1].id]?.issue == nil)
    }

    @Test func independentHomesKeepTheirOwnObservationsAndBothQuotaReadings() async throws {
        var fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        let profiles = try configure(&fixture)
        try write(fixture.credentialA, profile: profiles[0])
        try write(fixture.credentialB, profile: profiles[1])
        let model = try model(fixture)
        await model.refresh()
        expectBothQuotas(model, fixture: fixture)
        #expect(model.settings.active[.codex] == fixture.a.id)
        #expect(model.codexObservations[profiles[0].id]?.accountID == fixture.a.id)
        #expect(model.codexObservations[profiles[1].id]?.accountID == fixture.b.id)
        #expect(model.settings.selectedCodexClientID == profiles[0].id)
    }

    @Test func malformedSourceDoesNotBecomeEitherSavedAccountsQuotaError() async throws {
        var fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        let profiles = try configure(&fixture)
        let invalid = URL(fileURLWithPath: profiles[0].home).appendingPathComponent("auth.json")
        try SecureFiles.write(Data("not-json".utf8), to: invalid, expected: nil)
        try write(fixture.credentialB, profile: profiles[1])
        let model = try model(fixture)
        await model.refresh()
        expectBothQuotas(model, fixture: fixture)
        #expect(model.settings.active[.codex] == nil)
        #expect(model.codexObservations[profiles[0].id]?.issue != nil)
        #expect(model.codexObservations[profiles[1].id]?.issue == nil)
    }

    @Test func busyOperationPreventsChangingTheSelectedProfile() throws {
        var fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        let profiles = try configure(&fixture)
        let model = try model(fixture)
        let before = try SecureFiles.read(fixture.store.settingsURL)
        model.busy = true
        model.selectCodexProfile(profiles[1].id)
        #expect(model.settings.selectedCodexClientID == profiles[0].id)
        #expect(model.settings.active[.codex] == fixture.a.id)
        #expect(try SecureFiles.read(fixture.store.settingsURL) == before)
    }

    @Test func profileSaveDoesNotOverwriteExternalSettingsChange() throws {
        var fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        var profiles = try configure(&fixture)
        let model = try model(fixture)
        var external = try fixture.store.loadSettings()
        external.warnThreshold = 37
        let before = try SecureFiles.read(fixture.store.settingsURL)
        let externalData = try fixture.store.saveSettings(external, expected: before)
        profiles[1].name = "Renamed"
        #expect(throws: AppFailure.concurrentChange) {
            try model.saveCodexProfiles(profiles, selected: profiles[0].id)
        }
        #expect(try SecureFiles.read(fixture.store.settingsURL) == externalData)
        #expect(try fixture.store.loadSettings().warnThreshold == 37)
        #expect(try fixture.store.loadSettings().autoSwitch == false)
    }

    @Test func savingProfilesPreservesAutomationChoice() throws {
        var fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        var profiles = try configure(&fixture)
        let model = try model(fixture)
        profiles[1].name = "Renamed"
        try model.saveCodexProfiles(profiles, selected: profiles[0].id)
        #expect(model.settings.autoSwitch == false)
        let saved = try fixture.store.loadSettings()
        #expect(saved.autoSwitch == false)
        #expect(saved.codexClientProfiles?[1].name == "Renamed")
        #expect(saved.selectedCodexClientID == profiles[0].id)
    }

    @Test func explicitRecaptureNeverReplacesNewerVaultLoginWithOlderClientCopy() async throws {
        let fixture = try CodexMonitoringTests.Fixture(); defer { fixture.clean() }
        let newer = try CodexMonitoringTests.Fixture.credential("A", issued: 1_800_000_000, expires: 4_000_000_100)
        try fixture.store.saveCredential(fixture.a.id, credential: newer, vault: fixture.vault)
        try SecureFiles.write(fixture.credentialA.primary, to: fixture.clientURL, expected: nil)
        let runtime = AccountRuntime(store: fixture.store, vault: fixture.vault, fetchUsage: { _ in
            try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 25)], source: "fixture")
        })
        let model = AppModel(demo: false, store: fixture.store, runtime: runtime, startPolling: false)
        model.credentialAccess = .ready
        #expect(await model.add(provider: .codex, label: "Ignored replacement label", apiKey: ""))
        #expect(try fixture.store.loadCredential(fixture.a.id, vault: fixture.vault) == newer)
        #expect(model.settings.accounts == fixture.settings.accounts)
        #expect(try SecureFiles.read(fixture.clientURL) == fixture.credentialA.primary)
    }
}
