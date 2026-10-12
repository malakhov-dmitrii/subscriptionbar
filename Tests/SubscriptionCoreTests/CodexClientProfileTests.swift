import XCTest
@testable import SubscriptionCore

final class CodexClientProfileTests: XCTestCase {
    func testLegacySettingsKeepTheirHomeAndStableSelection() throws {
        var settings = Settings()
        settings.codexHome = "/tmp/legacy-codex"
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertNil(decoded.codexClientProfiles)
        XCTAssertEqual(decoded.effectiveCodexProfiles.count, 1)
        XCTAssertEqual(decoded.selectedCodexProfile?.id, CodexClientProfile.legacyID)
        XCTAssertEqual(decoded.selectedCodexProfile?.home, "/tmp/legacy-codex")
        XCTAssertNil(decoded.selectedCodexProfile?.applicationPath)
    }

    func testExplicitProfilesRoundTripWithoutFallingBackFromInvalidSelection() throws {
        let first = CodexClientProfile(name: "Work", home: "/tmp/work", applicationPath: "/Applications/Codex.app")
        let second = CodexClientProfile(name: "Personal", home: "/tmp/personal", applicationPath: "/Applications/codex2.app")
        var settings = Settings()
        settings.codexClientProfiles = [first, second]
        XCTAssertEqual(settings.selectedCodexProfile, first)
        settings.selectedCodexClientID = second.id
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.selectedCodexProfile, second)
        settings.selectedCodexClientID = UUID()
        XCTAssertNil(settings.selectedCodexProfile)
        settings.codexClientProfiles = []
        settings.selectedCodexClientID = nil
        XCTAssertTrue(settings.effectiveCodexProfiles.isEmpty)
        XCTAssertNil(settings.selectedCodexProfile)
    }

    func testValidationRejectsDuplicateHomesIncludingSymlinkAliases() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let profiles = [
            CodexClientProfile(name: "Work", home: source.path, applicationPath: "/Applications/Codex.app"),
            CodexClientProfile(name: "Alias", home: alias.path, applicationPath: "/Applications/codex2.app")
        ]
        XCTAssertThrowsError(try CodexClientProfile.validate(profiles)) { error in
            XCTAssertEqual(error as? CodexProfileValidationError, .duplicateHome)
        }
    }

    func testValidationNormalizesTildeAndAllowsOneAppForSeparateHomes() throws {
        let profiles = try CodexClientProfile.validate([
            CodexClientProfile(name: " Work ", home: "~/codex-work", applicationPath: "/Applications/Codex.app"),
            CodexClientProfile(name: "Personal", home: "~/codex-personal", applicationPath: "/Applications/Codex.app")
        ])
        XCTAssertEqual(profiles[0].name, "Work")
        XCTAssertEqual(profiles[0].home, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("codex-work").path)
        XCTAssertEqual(profiles[0].applicationPath, profiles[1].applicationPath)
        XCTAssertNotEqual(profiles[0].home, profiles[1].home)
    }

    func testInvalidTargetsAreRejectedBeforePersistence() throws {
        for home in ["", " ", "relative/codex", "/", "/Users/..", "/tmp/\u{0}codex"] {
            XCTAssertThrowsError(try CodexClientProfile.validate([
                CodexClientProfile(name: "Work", home: home, applicationPath: "/Applications/Codex.app")
            ]), home)
        }
        for app in [nil, "", "Codex.app", "/", "/Applications/Codex"] as [String?] {
            XCTAssertThrowsError(try CodexClientProfile.validate([
                CodexClientProfile(name: "Work", home: "/tmp/codex-work", applicationPath: app)
            ]))
        }
        let id = UUID()
        XCTAssertThrowsError(try CodexClientProfile.validate([
            CodexClientProfile(id: id, name: "Work", home: "/tmp/work", applicationPath: "/Applications/Codex.app"),
            CodexClientProfile(id: id, name: "Personal", home: "/tmp/personal", applicationPath: "/Applications/Codex.app")
        ])) { XCTAssertEqual($0 as? CodexProfileValidationError, .duplicateID) }
        XCTAssertThrowsError(try CodexClientProfile.validate([
            CodexClientProfile(name: " \n", home: "/tmp/work", applicationPath: "/Applications/Codex.app")
        ])) { XCTAssertEqual($0 as? CodexProfileValidationError, .missingName) }
    }

    func testLegacyRegisteredAppIsAllowedAndSourceCopyPreservesSavedAccounts() throws {
        var settings = Settings()
        let profile = CodexClientProfile(id: CodexClientProfile.legacyID, name: "Codex", home: "/tmp/source")
        let validated = try XCTUnwrap(CodexClientProfile.validate([profile]).first)
        XCTAssertNil(validated.applicationPath)
        let savedAccountID = UUID()
        settings.active[.codex] = savedAccountID
        let scoped = settings.settings(forCodexProfile: profile)
        XCTAssertEqual(scoped.codexHome, "/tmp/source")
        XCTAssertEqual(scoped.selectedCodexClientID, CodexClientProfile.legacyID)
        XCTAssertEqual(scoped.active[.codex], savedAccountID)
        XCTAssertEqual(settings.codexHome, "~/.codex")
    }

    func testCaseAliasesCannotConfigureTheSameExistingHomeTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("SOURCE")
        guard FileManager.default.fileExists(atPath: alias.path) else { throw XCTSkip("Case-sensitive test volume") }
        XCTAssertThrowsError(try CodexClientProfile.validate([
            CodexClientProfile(name: "One", home: source.path, applicationPath: "/Applications/Codex.app"),
            CodexClientProfile(name: "Two", home: alias.path, applicationPath: "/Applications/Codex.app")
        ])) { XCTAssertEqual($0 as? CodexProfileValidationError, .duplicateHome) }
    }
}
