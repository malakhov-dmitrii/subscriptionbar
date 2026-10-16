import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor struct ClaudeLoginDetectionTests {
    @Test func followsTheAccountClaudeCodeIsSignedInto() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalStore(root: root.appendingPathComponent("store"))
        let a = Account(provider: .claude, label: "A", identity: "uuid-a")
        let b = Account(provider: .claude, label: "B", identity: "uuid-b")
        var state = Settings()
        state.claudeHome = root.appendingPathComponent("claude").path
        state.enabledProviders = [.claude]
        state.accounts = [a, b]; state.active[.claude] = a.id
        _ = try store.saveSettings(state, expected: nil)
        let config = URL(fileURLWithPath: state.claudeHome).appendingPathComponent(".claude.json")
        func signIn(_ id: String, _ email: String) throws {
            let data = try JSONValue.object(["oauthAccount": .object([
                "accountUuid": .string(id), "emailAddress": .string(email)])]).data()
            try SecureFiles.write(data, to: config, expected: SecureFiles.read(config))
        }
        let model = AppModel(demo: false, store: store, startPolling: false, notificationSender: { _ in })

        try signIn("uuid-b", "b@example.test")
        await model.detectClaudeLogin()
        #expect(model.settings.active[.claude] == b.id)
        #expect(model.unsavedClaudeLogin == nil)
        #expect(try store.loadSettings().active[.claude] == b.id)

        try signIn("uuid-c", "c@example.test")
        await model.detectClaudeLogin()
        #expect(model.settings.active[.claude] == nil)
        #expect(model.unsavedClaudeLogin == "c@example.test")
    }

    @Test func unknownLoginIsAddedUnderItsVerifiedEmailAndBecomesActive() async throws {
        let f = try ClaudeCaptureIntegrationTests.Fixture(); defer { f.clean() }
        let model = AppModel(demo: false, store: f.store, runtime: f.runtime(), startPolling: false, notificationSender: { _ in })
        model.credentialAccess = .ready
        model.settings.accounts = []; model.settings.active[.claude] = nil
        try model.saveOrThrow()

        await model.detectClaudeLogin()

        let added = try #require(model.settings.accounts.first)
        #expect(added.identity == ClaudeCaptureIntegrationTests.accountB)
        #expect(added.label == "new@example.test")
        #expect(model.settings.active[.claude] == added.id)
        #expect(model.unsavedClaudeLogin == nil)
        #expect(try f.store.loadSettings().accounts.map(\.id) == [added.id])
    }

    @Test func onlyClaudeCodeItemsGoThroughTheSecurityTool() {
        #expect(ClaudeKeychainCLI.handles(KeychainItemSelector(service: "Claude Code-credentials", account: "me")))
        #expect(ClaudeKeychainCLI.handles(KeychainItemSelector(service: "Claude Code-credentials-1a2b3c4d", account: "me")))
        #expect(!ClaudeKeychainCLI.handles(KeychainItemSelector(service: KeychainVault.defaultService, account: "me")))
        #expect(!ClaudeKeychainCLI.handles(KeychainItemSelector(service: "Claude Code-credentials", account: "me",
                                                                useDataProtectionKeychain: true)))
        #expect(ClaudeKeychainCLI.quoted(#"a "b"\c"#) == #""a \"b\"\\c""#)
    }

    /// Writes and reads a throwaway login-keychain item; opt in with SUBSCRIPTIONBAR_KEYCHAIN_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUBSCRIPTIONBAR_KEYCHAIN_TESTS"] == "1"))
    func roundTripsThroughTheSecurityToolWithoutPrompting() throws {
        let selector = KeychainItemSelector(service: "Claude Code-credentials-sbtest\(UInt32.random(in: 0...UInt32.max))",
                                            account: NSUserName())
        defer {
            let cleanup = Process()
            cleanup.executableURL = ClaudeKeychainCLI.tool
            cleanup.arguments = ["delete-generic-password", "-s", selector.service, "-a", selector.account]
            cleanup.standardOutput = FileHandle.nullDevice; cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit()
        }
        #expect(try ClaudeKeychainCLI.read(selector) == nil)
        let first = Data(#"{"claudeAiOauth":{"accessToken":"fixture-1"}}"#.utf8)
        try KeychainClient.system.write(selector, data: first)
        #expect(try KeychainClient.system.read(selector) == first)
        let second = Data(#"{"claudeAiOauth":{"accessToken":"fixture-2 with \"quotes\""}}"#.utf8)
        try KeychainClient.system.write(selector, data: second)
        #expect(try KeychainClient.system.read(selector) == second)
    }
}
