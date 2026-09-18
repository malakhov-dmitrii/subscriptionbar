import Foundation
import Testing
@testable import SubscriptionCore

struct OAuthRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private func token(_ subject: String = "same-user", expires: Double = 1_900_003_600) throws -> String {
        let payload: JSONValue = .object(["sub": .string(subject), "exp": .number(expires),
            "https://api.openai.com/auth": .object(["chatgpt_account_id": .string("workspace")])])
        return "header." + (try payload.data()).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".signature"
    }
    private func fixture(_ provider: Provider, expires: Double = 1_900_000_100) throws -> CredentialEnvelope {
        let access = try token(expires: expires)
        let record: JSONValue
        let metadata: JSONValue?
        switch provider {
        case .claude:
            record = .object(["claudeAiOauth": .object(["accessToken": .string(access), "refreshToken": .string("refresh+&=value"),
                "expiresAt": .number(expires * 1000), "subscriptionType": .string("max")]), "unknown": .bool(true)])
            metadata = .object(["accountUuid": .string("same-user"), "emailAddress": .string("fixture@example.com"), "organizationUuid": .string("workspace")])
        case .codex:
            record = .object(["tokens": .object(["access_token": .string(access), "refresh_token": .string("refresh+&=value"),
                "id_token": .string(access), "account_id": .string("workspace"), "unknown": .string("nested")]), "unknown": .bool(true)])
            metadata = nil
        default:
            record = .object(["grok::client-fixture": .object(["key": .string(access), "refresh_token": .string("refresh+&=value"),
                "expires_at": .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: expires))),
                "oidc_client_id": .string("client-fixture"), "unknown": .string("nested")]), "unknown": .bool(true)])
            metadata = nil
        }
        var envelope = try CredentialParser.parse(provider: provider, data: record.data(), metadata: metadata)
        envelope.webSessionKey = "web-fixture"; envelope.webOrganizationID = "org-fixture"
        return envelope
    }

    @Test func expiryUnitsAndRequestContracts() throws {
        for provider in [Provider.claude, .codex, .grok] {
            #expect(try OAuthRefresher.prepare(fixture(provider, expires: 1_900_000_301), provider: provider, now: now) == nil)
            let prepared = try OAuthRefresher.prepare(fixture(provider), provider: provider, now: now)
            let request = try #require(prepared)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(try OAuthRefresher.prepare(fixture(provider, expires: 1_900_010_000), provider: provider, force: true, now: now) != nil)
            let body = try #require(request.httpBody)
            if provider == .codex {
                #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
                let fields = try JSONValue.parse(body)
                #expect(fields["client_id"]?.string == "app_EMoamEEZ73f0CkXaXp7hrann")
                #expect(fields["scope"]?.string == "openid profile email")
            } else {
                #expect(String(decoding: body, as: UTF8.self).contains("refresh%2B%26%3Dvalue"))
                #expect(request.url?.host == (provider == .claude ? "platform.claude.com" : "auth.x.ai"))
            }
        }
    }

    @Test func mergesPreserveIdentityUnknownFieldsAndOmittedTokens() throws {
        let response = try JSONValue.object(["access_token": .string(token()), "expires_in": .number(3600)]).data()
        for provider in [Provider.claude, .codex, .grok] {
            let original = try fixture(provider)
            let result = try OAuthRefresher.merge(data: response, into: original, provider: provider, now: now)
            #expect(result.identity == original.identity)
            #expect(result.metadata == original.metadata)
            #expect(result.webSessionKey == original.webSessionKey)
            #expect(result.webOrganizationID == original.webOrganizationID)
            let root = try JSONValue.parse(result.primary)
            #expect(root["unknown"] == .bool(true))
            switch provider {
            case .claude:
                #expect(root["claudeAiOauth"]?["refreshToken"]?.string == "refresh+&=value")
                #expect(root["claudeAiOauth"]?["expiresAt"]?.number == 1_900_003_600_000)
                #expect(root["claudeAiOauth"]?["subscriptionType"]?.string == "max")
            case .codex:
                #expect(root["tokens"]?["refresh_token"]?.string == "refresh+&=value")
                #expect(root["tokens"]?["id_token"] == (try JSONValue.parse(original.primary))["tokens"]?["id_token"])
                #expect(root["tokens"]?["unknown"]?.string == "nested")
            default:
                #expect(root["grok::client-fixture"]?["refresh_token"]?.string == "refresh+&=value")
                #expect(root["grok::client-fixture"]?["expires_at"]?.string == ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)))
                #expect(root["grok::client-fixture"]?["unknown"]?.string == "nested")
            }
        }
    }

    @Test func rejectsChangedIdentityAndMalformedRefresh() throws {
        let wrong = try JSONValue.object(["access_token": .string(token("other-user")), "expires_in": .number(3600)]).data()
        for provider in [Provider.claude, .codex, .grok] {
            let original = try fixture(provider)
            #expect(throws: AppFailure.invalidCredential) { try OAuthRefresher.merge(data: wrong, into: original, provider: provider, now: now) }
            for response in ["{}", "{\"access_token\":\"\"}", "{\"access_token\":\"opaque\",\"refresh_token\":null}"] {
                #expect(throws: AppFailure.invalidCredential) {
                    try OAuthRefresher.merge(data: Data(response.utf8), into: original, provider: provider, now: now)
                }
            }
        }
    }

    @Test func rotatedRefreshTokenReplacesOld() throws {
        let response = try JSONValue.object(["access_token": .string(token()), "refresh_token": .string("rotated"), "expires_in": .number(3600)]).data()
        let updated = try OAuthRefresher.merge(data: response, into: fixture(.claude), provider: .claude, now: now)
        #expect(try JSONValue.parse(updated.primary)["claudeAiOauth"]?["refreshToken"]?.string == "rotated")
    }
}
