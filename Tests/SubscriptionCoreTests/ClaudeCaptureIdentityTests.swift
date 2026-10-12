import Foundation
import Testing
@testable import SubscriptionCore

struct ClaudeCaptureIdentityTests {
    private let accountID = "11111111-2222-4333-8444-555555555555"
    private let organizationID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @Test func explicitCaptureUsesProviderIdentityAndDropsStaleMetadata() async throws {
        let primary = Data("{\"claudeAiOauth\":{\"accessToken\":\"opaque-fixture-token\",\"refreshToken\":\"fixture-refresh\"},\"unknown\":true}".utf8)
        var captured = CredentialEnvelope(primary: primary, identity: "stale-local-account",
            metadata: .object([
                "accountUuid": .string("stale-local-account"),
                "emailAddress": .string("stale@example.com"),
                "organizationUuid": .string("stale-local-org"),
                "accountRole": .string("admin"),
                "organizationRole": .string("owner"),
                "displayName": .string("Stale name")
            ]), keychainService: "Claude Code-credentials")
        captured.webSessionKey = "wrong-owner-fixture-session"
        captured.webOrganizationID = "stale-local-org"
        let response = try profile()
        let verifier = ClaudeIdentityVerifier(fetchProfile: { token in
            #expect(token == "opaque-fixture-token")
            return response
        })

        let resolved = try await verifier.resolve(captured)

        #expect(resolved.identity == accountID)
        #expect(resolved.primary == primary)
        #expect(resolved.keychainService == "Claude Code-credentials")
        #expect(resolved.metadata == .object([
            "accountUuid": .string(accountID),
            "emailAddress": .string("verified@example.com"),
            "organizationUuid": .string(organizationID),
            "displayName": .string("Verified name"),
            "organizationName": .string("Verified organization")
        ]))
        #expect(resolved.webSessionKey == nil)
        #expect(resolved.webOrganizationID == nil)
        #expect(captured.identity == "stale-local-account")
    }

    @Test func malformedOrAmbiguousProviderIdentityCannotBeCaptured() throws {
        let captured = try fixture()
        let valid = try JSONValue.parse(profile())
        let serverAccount = try #require(valid["account"]?.object)
        let serverOrganization = try #require(valid["organization"]?.object)
        var invalid: [Data] = [Data("{".utf8), Data("null".utf8), Data("{}".utf8)]
        for id in [JSONValue.null, .string(""), .string("not-an-account-uuid"), .number(1)] {
            var account = serverAccount
            account["uuid"] = id
            invalid.append(try JSONValue.object(["account": .object(account), "organization": .object(serverOrganization)]).data())
            var organization = serverOrganization
            organization["uuid"] = id
            invalid.append(try JSONValue.object(["account": .object(serverAccount), "organization": .object(organization)]).data())
        }
        for email in [JSONValue.null, .string(""), .string("invalid"), .string("@example.com"),
                      .string("verified@example.com\r\nInjected: yes"), .string("verified\u{0000}@example.com"), .bool(true)] {
            var account = serverAccount
            account["email"] = email
            invalid.append(try JSONValue.object(["account": .object(account), "organization": .object(serverOrganization)]).data())
        }
        for alias in [JSONValue.string("other@example.com"), .null, .number(1)] {
            var account = serverAccount
            account["email_address"] = alias
            invalid.append(try JSONValue.object(["account": .object(account), "organization": .object(serverOrganization)]).data())
        }
        var accountWithoutEmail = serverAccount
        accountWithoutEmail["email"] = nil
        invalid.append(try JSONValue.object(["account": .object(accountWithoutEmail), "organization": .object(serverOrganization)]).data())
        invalid.append(try JSONValue.object(["account": .object(serverAccount)]).data())
        for data in invalid {
            #expect(throws: AppFailure.invalidCredential) {
                try ClaudeIdentityVerifier.resolveProfile(data: data, envelope: captured)
            }
        }
    }

    @Test func providerEmailAliasesMustAgreeAndUnsafeDisplayFieldsAreNotCopied() throws {
        let response = try JSONValue.object([
            "account": .object([
                "uuid": .string(accountID),
                "email": .string("verified@example.com"),
                "email_address": .string("VERIFIED@example.com"),
                "emailAddress": .string("verified@EXAMPLE.com"),
                "display_name": .string("Injected\nrole: owner"),
                "role": .string("admin")
            ]),
            "organization": .object([
                "uuid": .string(organizationID),
                "name": .string(String(repeating: "x", count: 201)),
                "role": .string("owner")
            ])
        ]).data()
        let resolved = try ClaudeIdentityVerifier.resolveProfile(data: response, envelope: fixture())
        #expect(resolved.metadata == .object([
            "accountUuid": .string(accountID),
            "emailAddress": .string("verified@example.com"),
            "organizationUuid": .string(organizationID)
        ]))
    }

    @Test func tokenSubjectCannotContradictProviderAccount() throws {
        let response = try profile()
        for subject in [JSONValue.string("other-account"), .null, .number(1)] {
            let captured = try jwtFixture(subject)
            #expect(throws: AppFailure.invalidCredential) {
                try ClaudeIdentityVerifier.resolveProfile(data: response, envelope: captured)
            }
        }
        let captured = try jwtFixture(.string(accountID))
        let resolved = try ClaudeIdentityVerifier.resolveProfile(data: response, envelope: captured)
        #expect(resolved.identity == accountID)
        #expect(resolved.primary == captured.primary)
    }

    @Test func invalidCaptureTokenNeverReachesProfileTransport() async throws {
        let verifier = ClaudeIdentityVerifier(fetchProfile: { _ in
            Issue.record("Invalid capture invoked the profile transport")
            throw AppFailure.invalidCredential
        })
        for token in ["", "with space", "bad\r\nheader", "bad\u{0000}token"] {
            let captured = try fixture(token: token)
            await #expect(throws: AppFailure.invalidCredential) { try await verifier.resolve(captured) }
        }
        for primary in [Data("{".utf8), Data("{}".utf8)] {
            let captured = CredentialEnvelope(primary: primary, identity: "stale")
            await #expect(throws: AppFailure.invalidCredential) { try await verifier.resolve(captured) }
        }
    }

    @Test func savedAccountVerificationStillRejectsStaleBinding() async throws {
        let response = try profile()
        let verifier = ClaudeIdentityVerifier(fetchProfile: { _ in response })
        for metadata: JSONValue in [
            .object(["emailAddress": .string("other@example.com"), "organizationUuid": .string(organizationID)]),
            .object(["emailAddress": .string("verified@example.com"), "organizationUuid": .string("another-org")])
        ] {
            await #expect(throws: AppFailure.invalidCredential) {
                try await verifier.verify(token: "opaque-fixture-token", metadata: metadata)
            }
        }
        try await verifier.verify(token: "opaque-fixture-token", metadata: .object([
            "emailAddress": .string("VERIFIED@example.com"), "organizationUuid": .string(organizationID)
        ]))
    }

    @Test func profileTransportFailureDoesNotProduceResolvedIdentity() async throws {
        let verifier = ClaudeIdentityVerifier(fetchProfile: { _ in throw AppFailure.message("fixture transport failed") })
        let captured = try fixture()
        await #expect(throws: AppFailure.message("fixture transport failed")) { try await verifier.resolve(captured) }
        #expect(captured.identity == "stale-local-account")
    }

    private func fixture(token: String = "opaque-fixture-token") throws -> CredentialEnvelope {
        let primary = try JSONValue.object(["claudeAiOauth": .object(["accessToken": .string(token)])]).data()
        return CredentialEnvelope(primary: primary, identity: "stale-local-account")
    }

    private func jwtFixture(_ subject: JSONValue) throws -> CredentialEnvelope {
        let payload = try JSONValue.object(["sub": subject]).data().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try fixture(token: "fixture.\(payload).signature")
    }

    private func profile() throws -> Data {
        try JSONValue.object([
            "account": .object([
                "uuid": .string(accountID),
                "email": .string("verified@example.com"),
                "display_name": .string("Verified name")
            ]),
            "organization": .object([
                "uuid": .string(organizationID),
                "name": .string("Verified organization")
            ])
        ]).data()
    }
}
