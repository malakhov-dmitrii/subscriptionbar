import Foundation
import Testing
@testable import SubscriptionCore

struct ImportTests {
    private let home = URL(fileURLWithPath: "/fixture")
    private func jwt(_ subject: String, account: String) throws -> String {
        let data = try JSONValue.object(["sub": .string(subject), "https://api.openai.com/auth": .object(["chatgpt_account_id": .string(account)])]).data()
        return "header." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".sig"
    }
    private func codex(_ subject: String) throws -> Data {
        let token = try jwt(subject, account: "workspace")
        return try JSONValue.object(["tokens": .object(["access_token": .string(token), "id_token": .string(token), "account_id": .string("workspace")])]).data()
    }

    @Test func importsCodexProfilesAlongsideCurrent() throws {
        let id = UUID(), activeData = try codex("user-one"), other = try codex("user-two")
        let current = try CredentialParser.parse(provider: .codex, data: activeData)
        let root = home.appendingPathComponent("Library/Application Support/Codex Account Switcher")
        let files: [String: Data] = [
            root.appendingPathComponent("accounts.json").path: Data("{\"accounts\":[{\"id\":\"\(id.uuidString)\",\"displayName\":\"Second\"}]}".utf8),
            root.appendingPathComponent("accounts/\(id.uuidString)/auth.json").path: other
        ]
        let importer = ExistingAccountsImporter(home: home, read: { files[$0.path] }, readSecret: { _, _ in nil }, capture: { provider, _ in
            guard provider == .codex else { throw AppFailure.missingCredential }
            return current
        })
        let report = importer.discoverReport(settings: Settings())
        #expect(report.accounts.count == 2)
        #expect(report.accounts.filter(\.isActive).count == 1)
        #expect(report.accounts.last?.label == "Second")
        #expect(report.accounts.last?.credential.identity == "user-two:workspace")
    }

    @Test func savedDuplicatePreservesCurrentCredentialBytes() throws {
        let id = UUID(), saved = try codex("same-user")
        var current = try CredentialParser.parse(provider: .codex, data: saved)
        var currentJSON = try JSONValue.parse(saved).object ?? [:]
        currentJSON["refresh_marker"] = .string("fresh-fixture")
        current.primary = try JSONValue.object(currentJSON).data()
        let captured = current
        let importer = ExistingAccountsImporter(home: home, read: { url in
            if url.lastPathComponent == "accounts.json" {
                return Data("{\"accounts\":[{\"id\":\"\(id.uuidString)\",\"displayName\":\"Saved name\"}]}".utf8)
            }
            return url.lastPathComponent == "auth.json" ? saved : nil
        }, readSecret: { _, _ in nil }, capture: { provider, _ in
            guard provider == .codex else { throw AppFailure.missingCredential }
            return captured
        })
        let report = importer.discoverReport(settings: Settings())
        #expect(report.accounts.count == 1)
        #expect(report.accounts.first?.credential.primary == captured.primary)
        #expect(report.accounts.first?.label == "Saved name")
        #expect(report.accounts.first?.isActive == true)
    }

    @Test func importsTrackerWebOnlyUsingExactKeychainAccount() throws {
        let id = UUID(), org = UUID().uuidString
        let profiles = Data("[{\"id\":\"\(id.uuidString)\",\"name\":\"Claude web\",\"provider\":\"anthropic\",\"organizationId\":\"\(org)\"}]".utf8)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["profiles_v3": profiles], format: .binary, options: 0)
        let importer = ExistingAccountsImporter(home: home, read: { url in url.path.hasSuffix("HamedElfayome.Claude-Usage.plist") ? plist : nil }, readSecret: { service, account in
            #expect(service == "com.claudeusagetracker.profile-credentials")
            if account == id.uuidString + ".claude-session-key" { return Data("fixture-session".utf8) }
            #expect(account == id.uuidString + ".cli-credentials")
            throw AppFailure.missingCredential
        }, capture: { _, _ in throw AppFailure.missingCredential })
        let report = importer.discoverReport(settings: Settings())
        #expect(report.accounts.count == 1)
        let item = try #require(report.accounts.first)
        #expect(item.monitoringOnly)
        #expect(!item.isActive)
        #expect(item.credential.primary.isEmpty)
        #expect(item.credential.identity == "web-org:" + org)
        #expect(item.credential.webSessionKey == "fixture-session")
        #expect(item.credential.webOrganizationID == org)
    }

    @Test func invalidRegistryProfileDoesNotHideOtherSourcesOrLeakError() throws {
        let grok = CredentialEnvelope(primary: Data("fixture".utf8), identity: "grok-user")
        let importer = ExistingAccountsImporter(home: home, read: { url in
            url.lastPathComponent == "accounts.json" ? Data("{\"accounts\":[{\"id\":\"../../secret\"}]}".utf8) : nil
        }, readSecret: { _, _ in nil }, capture: { provider, _ in
            guard provider == .grok else { throw AppFailure.message("sensitive fixture error") }
            return grok
        })
        let report = importer.discoverReport(settings: Settings())
        #expect(report.accounts.count == 1)
        #expect(report.accounts.first?.provider == .grok)
        #expect(report.warnings.count == 3)
        #expect(!report.warnings.joined().contains("sensitive"))
    }
}
