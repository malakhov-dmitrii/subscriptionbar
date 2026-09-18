import Foundation
import Testing
@testable import SubscriptionCore

struct UsageAPITests {
    @Test func claudeProfileChecksEmailAndOrganization() throws {
        let metadata: JSONValue = .object(["emailAddress": .string("User@example.com"), "organizationUuid": .string("org-A")])
        for field in ["email", "email_address", "emailAddress"] {
            let data = Data("{\"account\":{\"\(field)\":\"user@EXAMPLE.com\"},\"organization\":{\"uuid\":\"org-A\"}}".utf8)
            try ClaudeIdentityVerifier.verifyProfile(data: data, metadata: metadata)
        }
        for json in ["{}", "null", "{", "{\"account\":{\"email\":\"other@example.com\"},\"organization\":{\"uuid\":\"org-A\"}}",
                     "{\"account\":{\"email\":\"user@example.com\"},\"organization\":{\"uuid\":\"org-B\"}}",
                     "{\"account\":{\"email\":\"user@example.com\",\"email_address\":\"other@example.com\"},\"organization\":{\"uuid\":\"org-A\"}}",
                     "{\"account\":{\"email\":\"user@example.com\"}}"] {
            #expect(throws: AppFailure.invalidCredential) {
                try ClaudeIdentityVerifier.verifyProfile(data: Data(json.utf8), metadata: metadata)
            }
        }
        #expect(throws: AppFailure.invalidCredential) {
            try ClaudeIdentityVerifier.verifyProfile(data: Data("{}".utf8), metadata: .object([:]))
        }
    }

    private func token(subject: String, account: String? = nil) throws -> String {
        var payload: [String: JSONValue] = ["sub": .string(subject)]
        if let account { payload["https://api.openai.com/auth"] = .object(["chatgpt_account_id": .string(account)]) }
        let encoded = try JSONValue.object(payload).data().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "fixture.\(encoded).signature"
    }

    @Test func mismatchedCredentialIdentityFailsClosed() throws {
        let claude = try JSONValue.object(["claudeAiOauth": .object(["accessToken": .string(token(subject: "account-A"))])]).data()
        #expect(throws: AppFailure.invalidCredential) {
            try CredentialParser.parse(provider: .claude, data: claude, metadata: .object(["accountUuid": .string("account-B")]))
        }
        for (subject, account) in [("different-user", "workspace-A"), ("same-user", "workspace-B")] {
            let codex = try JSONValue.object(["tokens": .object([
                "id_token": .string(token(subject: "same-user", account: "workspace-A")),
                "access_token": .string(token(subject: subject, account: account)),
                "account_id": .string("workspace-A")
            ])]).data()
            #expect(throws: AppFailure.invalidCredential) { try CredentialParser.parse(provider: .codex, data: codex) }
        }
        let matching = try JSONValue.object(["tokens": .object([
            "id_token": .string(token(subject: "same-user", account: "workspace-A")),
            "access_token": .string(token(subject: "same-user", account: "workspace-A")),
            "account_id": .string("workspace-A")
        ])]).data()
        #expect(try CredentialParser.parse(provider: .codex, data: matching).identity == "same-user:workspace-A")
    }

    private func parse(_ provider: Provider, _ json: String) throws -> UsageSnapshot {
        try UsageAPI.parse(provider: provider, data: Data(json.utf8), source: "fixture",
                           now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func quotaBoundariesAndModelLimits() throws {
        for percent in [0, 99, 100] {
            let snapshot = try parse(.claude, "{\"five_hour\":{\"utilization\":\(percent)},\"seven_day\":null,\"seven_day_sonnet\":{\"utilization\":100}}")
            #expect(snapshot.remainingPercent == Double(100 - percent))
            #expect(snapshot.windows.count == 1)
        }
        let snapshot = try parse(.claude, """
        {"five_hour":{"utilization":2,"resets_at":"2030-01-01T00:00:00.000Z"},
         "seven_day":{"utilization":99,"resets_at":"2030-01-02T00:00:00Z"}}
        """)
        #expect(snapshot.remainingPercent == 1)
        #expect(snapshot.windows.allSatisfy { $0.resetsAt != nil })
    }

    @Test func missingAndMalformedAreNeverZero() throws {
        for json in ["{}", "null", "[]", "{", "{\"five_hour\":null}",
                     "{\"five_hour\":{}}", "{\"five_hour\":{\"utilization\":null}}",
                     "{\"five_hour\":{\"utilization\":true}}",
                     "{\"five_hour\":{\"utilization\":\"nan\"}}",
                     "{\"five_hour\":{\"utilization\":101}}",
                     "{\"five_hour\":{\"utilization\":-1}}",
                     "{\"five_hour\":{\"utilization\":0,\"resets_at\":\"bad\"}}"] {
            #expect(throws: AppFailure.invalidUsage) { try parse(.claude, json) }
        }
        #expect(throws: AppFailure.invalidUsage) {
            try parse(.grok, "{\"config\":{\"currentPeriod\":{\"type\":\"WEEKLY\"}}}")
        }
        #expect(throws: AppFailure.invalidUsage) { try parse(.openRouter, "{\"data\":{\"total_credits\":10}}") }
    }

    @Test func codexEpochAndGrokExplicitPercent() throws {
        let codex = try parse(.codex, """
        {"rate_limit":{"primary_window":{"used_percent":99,"reset_at":1900000000},"secondary_window":null}}
        """)
        #expect(codex.remainingPercent == 1)
        #expect(codex.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_900_000_000))
        for value in [0, 99, 100] {
            let grok = try parse(.grok, "{\"config\":{\"creditUsagePercent\":\(value)}}")
            #expect(grok.remainingPercent == Double(100 - value))
        }
    }

    @Test func zaiExcludesMCPAndGoIncludesAllWindows() throws {
        let zai = try parse(.zai, """
        {"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":0},{"type":"TIME_LIMIT","percentage":100}]}}
        """)
        #expect(zai.remainingPercent == 100)
        #expect(zai.windows.count == 1)
        let go = try parse(.openCodeGo, """
        {"usage":{
          "rolling":{"status":"ok","percent":0,"resetsAt":"2030-01-01T00:00:00Z"},
          "weekly":{"status":"ok","percent":99,"resetsAt":"2030-01-02T00:00:00Z"},
          "monthly":{"status":"rate-limited","percent":100,"resetsAt":"2030-02-01T00:00:00Z"}}}
        """)
        #expect(go.windows.map(\.usedPercent) == [0, 99, 100])
        #expect(go.remainingPercent == 0)
        #expect(throws: AppFailure.invalidUsage) { try parse(.openCodeGo, "{\"usage\":{}}") }
        #expect(throws: AppFailure.invalidUsage) {
            try parse(.zai, "{\"data\":{\"limits\":[{\"type\":\"TIME_LIMIT\",\"percentage\":0}]}}")
        }
    }

    @Test func balancesPreserveCurrencyAndDoNotInventPercentage() throws {
        let router = try parse(.openRouter, "{\"data\":{\"total_credits\":100.5,\"total_usage\":25.75}}")
        #expect(router.balances == [try Balance(currency: "USD", available: 74.75)])
        #expect(router.remainingPercent == nil)
        let deepseek = try parse(.deepSeek, """
        {"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00"},
          {"currency":"USD","total_balance":"3.25"}]}
        """)
        #expect(deepseek.balances.map(\.currency) == ["CNY", "USD"])
        #expect(deepseek.balances.map(\.available) == [110, 3.25])
        for json in ["{\"is_available\":true,\"balance_infos\":[]}",
                     "{\"is_available\":true,\"balance_infos\":[{\"currency\":\"USD\",\"total_balance\":\"Infinity\"}]}"] {
            #expect(throws: AppFailure.invalidUsage) { try parse(.deepSeek, json) }
        }
    }

    @Test func requestsUseOnlyReadOnlyEndpointsAndCorrectAuth() throws {
        for provider in Provider.allCases where provider != .cursor {
            let request = try UsageAPI.request(UsageCredential(provider: provider, bearer: "fixture-token"))
            #expect(request.httpMethod == "GET")
            #expect(request.url?.scheme == "https")
            #expect(request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == (provider == .zai ? "fixture-token" : "Bearer fixture-token"))
        }
        let web = try UsageAPI.request(UsageCredential(provider: .claude, bearer: "", claudeSessionKey: "fixture-session",
                                                     claudeOrganizationID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(web.url?.host == "claude.ai")
        #expect(web.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(web.value(forHTTPHeaderField: "Cookie") == "sessionKey=fixture-session")
        #expect(throws: AppFailure.invalidCredential) {
            try UsageAPI.request(UsageCredential(provider: .claude, bearer: "", claudeSessionKey: "x", claudeOrganizationID: "../other"))
        }
        #expect(throws: AppFailure.invalidCredential) {
            try UsageAPI.request(UsageCredential(provider: .grok, bearer: "bad\r\nheader"))
        }
    }
}
