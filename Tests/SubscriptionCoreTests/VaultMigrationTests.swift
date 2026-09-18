import Foundation
import Testing
@testable import SubscriptionCore

struct VaultMigrationTests {
    @Test func partialConsolidatedEntryWinsOverNewerActiveSourceExactly() throws {
        let (activeAccount, live) = try fixture(.codex, user: "active")
        let (otherAccount, other) = try fixture(.grok, user: "other")
        var existing = live
        var oldPrimary = try JSONValue.parse(existing.primary).object ?? [:]
        oldPrimary["oldMarker"] = .bool(true)
        existing.primary = try JSONValue.object(oldPrimary).data()
        let exact = try JSONEncoder().encode(existing)
        let key = "account:" + activeAccount.id.uuidString
        var settings = Settings(); settings.accounts = [activeAccount, otherAccount]; settings.active[.codex] = activeAccount.id
        var report = ImportReport(); report.accounts = [source(activeAccount, live), source(otherAccount, other)]
        var migration = VaultMigration()
        var reads: [String] = []
        let entries = try migration.gatherNonInteractive(settings: settings, existingEntries: [key: exact], readLegacy: {
            reads.append($0); return nil
        }, discoverSources: { report })
        #expect(entries?.count == 2)
        #expect(entries?[key] == exact)
        #expect(!reads.contains(key))
        #expect(migration.isComplete)
    }

    @Test func unknownConsolidatedKeyRejectsBeforeStartingMigration() throws {
        var migration = VaultMigration()
        #expect(throws: AppFailure.invalidCredential) {
            try migration.gatherNonInteractive(settings: Settings(), existingEntries: ["unexpected": Data()],
                readLegacy: { _ in nil }, discoverSources: { ImportReport() })
        }
        #expect(!migration.isComplete)
        #expect(migration.totalCount == 0)
    }

    private func fixture(_ provider: Provider, user: String) throws -> (Account, CredentialEnvelope) {
        let payload = try JSONValue.object(["sub": .string(user), "https://api.openai.com/auth": .object(["chatgpt_account_id": .string("workspace")])]).data()
        let jwt = "h." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        let primary: JSONValue
        let metadata: JSONValue?
        switch provider {
        case .claude:
            primary = .object(["claudeAiOauth": .object(["accessToken": .string(jwt)])])
            metadata = .object(["accountUuid": .string(user)])
        case .codex:
            primary = .object(["tokens": .object(["access_token": .string(jwt), "id_token": .string(jwt), "account_id": .string("workspace")])])
            metadata = nil
        default:
            primary = .object(["fixture": .object(["key": .string(jwt)])])
            metadata = nil
        }
        let envelope = try CredentialParser.parse(provider: provider, data: primary.data(), metadata: metadata)
        return (Account(provider: provider, label: user, identity: envelope.identity), envelope)
    }
    private func source(_ account: Account, _ envelope: CredentialEnvelope, active: Bool = true) -> ImportedAccount {
        ImportedAccount(label: account.label, provider: account.provider, credential: envelope,
                        isActive: active, source: "fixture", monitoringOnly: false)
    }

    @Test func fourAccountsNeedOnlyOneExplicitAuthorization() throws {
        var settings = Settings()
        var report = ImportReport()
        var claudeKey = ""
        var claudeData = Data()
        for (provider, name) in [(Provider.claude, "claude"), (.codex, "codex-one"), (.codex, "codex-two"), (.grok, "grok")] {
            var (account, envelope) = try fixture(provider, user: name)
            settings.accounts.append(account)
            if provider == .claude {
                claudeKey = "account:" + account.id.uuidString
                envelope.webSessionKey = "saved-web-session"; envelope.webOrganizationID = "saved-org"
                claudeData = try JSONEncoder().encode(envelope)
            } else { report.accounts.append(source(account, envelope)) }
        }
        var migration = VaultMigration()
        var reads = 0
        let initial = try migration.gatherNonInteractive(settings: settings, readLegacy: { _ in reads += 1; return nil }, discoverSources: { report })
        #expect(reads == 4)
        #expect(initial == nil)
        #expect(migration.completedEntries == nil)
        #expect(migration.pendingCount == 1)
        #expect(migration.completedCount == 3)
        var prompts = 0
        let entries = try migration.authorizeNext { key in prompts += 1; #expect(key == claudeKey); return claudeData }
        #expect(prompts == 1)
        #expect(entries?.count == 4)
        #expect(migration.isComplete)
        _ = try migration.authorizeNext { _ in prompts += 1; return nil }
        #expect(prompts == 1)
    }

    @Test func cancellationAndSubsequentClicksInvokeOnlyOnce() throws {
        let (first, firstEnvelope) = try fixture(.codex, user: "one")
        let (second, secondEnvelope) = try fixture(.grok, user: "two")
        var settings = Settings(); settings.accounts = [first, second]
        var migration = VaultMigration()
        _ = try migration.gatherNonInteractive(settings: settings, readLegacy: { _ in nil }, discoverSources: { ImportReport() })
        var prompts = 0
        #expect(try migration.authorizeNext { _ in prompts += 1; return nil } == nil)
        #expect(prompts == 1)
        #expect(migration.pendingCount == 2)
        _ = try migration.authorizeNext { _ in prompts += 1; return try JSONEncoder().encode(firstEnvelope) }
        #expect(prompts == 2)
        #expect(migration.pendingCount == 1)
        #expect(migration.completedEntries == nil)
        _ = try migration.authorizeNext { _ in prompts += 1; return try JSONEncoder().encode(secondEnvelope) }
        #expect(prompts == 3)
        #expect(migration.completedEntries?.count == 2)
    }

    @Test func identityMismatchNeverCompletes() throws {
        let (account, _) = try fixture(.codex, user: "expected")
        let (_, other) = try fixture(.codex, user: "other")
        var settings = Settings(); settings.accounts = [account]
        var migration = VaultMigration()
        _ = try migration.gatherNonInteractive(settings: settings, readLegacy: { _ in nil }, discoverSources: { ImportReport() })
        #expect(throws: AppFailure.invalidCredential) {
            try migration.authorizeNext { _ in try JSONEncoder().encode(other) }
        }
        #expect(migration.pendingCount == 1)
        #expect(migration.completedEntries == nil)
    }

    @Test func activeSourceRetainsManagedWebAndUnknownEnvelopeFields() throws {
        let (account, live) = try fixture(.claude, user: "same-user")
        var saved = live
        var stale = try JSONValue.parse(saved.primary).object ?? [:]
        stale["old_marker"] = .bool(true)
        saved.primary = try JSONValue.object(stale).data()
        saved.webSessionKey = "paired-session"; saved.webOrganizationID = "paired-org"
        var stored = try JSONValue.parse(JSONEncoder().encode(saved)).object ?? [:]
        stored["futureEnvelopeField"] = .object(["keep": .bool(true)])
        let data = try JSONValue.object(stored).data()
        var settings = Settings(); settings.accounts = [account]; settings.active[.claude] = account.id
        var report = ImportReport(); report.accounts = [source(account, live)]
        var migration = VaultMigration()
        let entries = try migration.gatherNonInteractive(settings: settings, readLegacy: { _ in data }, discoverSources: { report })
        let resultData = try #require(entries?["account:" + account.id.uuidString])
        let result = try JSONDecoder().decode(CredentialEnvelope.self, from: resultData)
        #expect(result.primary == live.primary)
        #expect(result.webSessionKey == "paired-session")
        #expect(result.webOrganizationID == "paired-org")
        #expect(try JSONValue.parse(resultData)["futureEnvelopeField"] == .object(["keep": .bool(true)]))
    }

    @Test func browserExtrasRequireValidationAndBlockAggregateUntilReady() throws {
        var migration = VaultMigration()
        _ = try migration.gatherNonInteractive(settings: Settings(), extraKeys: ["browser:fixture"], readLegacy: { _ in nil }, discoverSources: { ImportReport() })
        #expect(migration.completedEntries == nil)
        #expect(throws: AppFailure.invalidCredential) {
            try migration.authorizeNext { _ in Data("[]".utf8) }
        }
        let result = try migration.authorizeNext(validateExtra: { key, data in
            guard key == "browser:fixture", try JSONValue.parse(data).array != nil else { throw AppFailure.invalidCredential }
        }, readLegacyInteractive: { _ in Data("[]".utf8) })
        #expect(result?.count == 1)
    }
}
