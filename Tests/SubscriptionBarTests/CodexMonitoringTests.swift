import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

@MainActor struct CodexMonitoringTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexMonitoring-\(UUID())")
        let store: LocalStore
        let vault: KeychainVault
        let a: Account
        let b: Account
        let credentialA: CredentialEnvelope
        let credentialB: CredentialEnvelope
        var settings: Settings

        init() throws {
            store = LocalStore(root: root.appendingPathComponent("store"))
            let raw = CodexRecoveryIntegrationTests.Raw()
            vault = KeychainVault(root: store.root, client: raw.client())
            credentialA = try Self.credential("A")
            credentialB = try Self.credential("B")
            a = Account(provider: .codex, label: "A", identity: credentialA.identity)
            b = Account(provider: .codex, label: "B", identity: credentialB.identity)
            settings = Settings()
            settings.accounts = [a, b]
            settings.active[.codex] = a.id
            settings.enabledProviders = [.codex]
            settings.codexHome = root.appendingPathComponent("client").path
            settings.autoSwitch = false
            _ = try store.saveSettings(settings, expected: nil)
            try store.saveCredential(a.id, credential: credentialA, vault: vault)
            try store.saveCredential(b.id, credential: credentialB, vault: vault)
        }
        static func credential(_ user: String, issued: Double = 1_700_000_000,
                               expires: Double = 4_000_000_000) throws -> CredentialEnvelope {
            let payload: JSONValue = .object(["sub": .string(user), "iat": .number(issued), "exp": .number(expires),
                "https://api.openai.com/auth": .object(["chatgpt_user_id": .string(user), "chatgpt_account_id": .string("workspace")])])
            let token = "fixture." + (try payload.data()).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
            return try CredentialParser.parse(provider: .codex, data: JSONValue.object(["tokens": .object([
                "id_token": .string(token), "access_token": .string(token), "account_id": .string("workspace")
            ])]).data())
        }
        var clientURL: URL { URL(fileURLWithPath: settings.codexHome).appendingPathComponent("auth.json") }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test(arguments: [true, false]) func savedQuotaSurvivesClientSwitchOrLogout(clientHasOtherLogin: Bool) async throws {
        let f = try Fixture(); defer { f.clean() }
        if clientHasOtherLogin { try SecureFiles.write(f.credentialB.primary, to: f.clientURL, expected: nil) }
        let before = try SecureFiles.read(f.clientURL)
        let bearer = try #require(try JSONValue.parse(f.credentialA.primary)["tokens"]?["access_token"]?.string)
        let runtime = AccountRuntime(store: f.store, vault: f.vault, fetchUsage: { request in
            #expect(request.provider == .codex)
            #expect(request.bearer == bearer)
            return try UsageSnapshot(windows: [UsageWindow("Primary", usedPercent: 23)], source: "fixture")
        })

        let reading = try await runtime.fetch(account: f.a, settings: f.settings)

        #expect(reading.remainingPercent == 77)
        #expect(try SecureFiles.read(f.clientURL) == before)
        #expect(try f.store.loadCredential(f.a.id, vault: f.vault) == f.credentialA)
    }
}
