import Foundation

private final class ClaudeProfileRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Resolves explicit captures from the provider and verifies saved account bindings separately.
public struct ClaudeIdentityVerifier: Sendable {
    public typealias ProfileFetcher = @Sendable (String) async throws -> Data
    private let profileFetcher: ProfileFetcher

    public init(fetchProfile: @escaping ProfileFetcher = ClaudeIdentityVerifier.fetchProfile) {
        profileFetcher = fetchProfile
    }

    /// Capture may have stale local metadata. Only the authenticated profile supplies identity.
    public func resolve(_ envelope: CredentialEnvelope) async throws -> CredentialEnvelope {
        let token = try Self.accessToken(envelope)
        let data = try await profileFetcher(token)
        return try Self.resolveProfile(data: data, envelope: envelope)
    }

    public static func resolveProfile(data: Data, envelope: CredentialEnvelope) throws -> CredentialEnvelope {
        let token = try accessToken(envelope)
        let profile: JSONValue
        do { profile = try JSONValue.parse(data) } catch { throw AppFailure.invalidCredential }
        guard let account = profile["account"]?.object,
              let accountID = account["uuid"]?.string, UUID(uuidString: accountID) != nil,
              let organization = profile["organization"]?.object,
              let organizationID = organization["uuid"]?.string, UUID(uuidString: organizationID) != nil else {
            throw AppFailure.invalidCredential
        }
        var emails: [String] = []
        for field in ["email", "email_address", "emailAddress"] {
            guard let value = account[field] else { continue }
            guard let email = value.string, validEmail(email) else { throw AppFailure.invalidCredential }
            emails.append(email)
        }
        guard let email = emails.first,
              emails.allSatisfy({ $0.lowercased() == email.lowercased() }) else {
            throw AppFailure.invalidCredential
        }
        if let subject = CredentialParser.jwt(token)?["sub"] {
            guard subject.string == accountID else { throw AppFailure.invalidCredential }
        }
        var metadata: [String: JSONValue] = [
            "accountUuid": .string(accountID),
            "emailAddress": .string(email),
            "organizationUuid": .string(organizationID)
        ]
        if let displayName = displayText(account["display_name"]) { metadata["displayName"] = .string(displayName) }
        if let organizationName = displayText(organization["name"]) { metadata["organizationName"] = .string(organizationName) }
        // A successful OAuth profile request does not authenticate an attached browser session.
        return CredentialEnvelope(primary: envelope.primary, identity: accountID, metadata: .object(metadata),
                                  keychainService: envelope.keychainService)
    }

    private static func accessToken(_ envelope: CredentialEnvelope) throws -> String {
        let value: JSONValue
        do { value = try JSONValue.parse(envelope.primary) } catch { throw AppFailure.invalidCredential }
        guard let token = value["claudeAiOauth"]?["accessToken"]?.string else { throw AppFailure.invalidCredential }
        try validateToken(token)
        return token
    }

    private static func validateToken(_ token: String) throws {
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AppFailure.invalidCredential
        }
    }

    private static func validEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            && !email.contains(where: { $0.isWhitespace || $0.isNewline })
            && !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func displayText(_ value: JSONValue?) -> String? {
        guard let text = value?.string, !text.isEmpty, text.count <= 200,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return text
    }

    public func verifyWeb(sessionKey: String, metadata: JSONValue) async throws {
        guard !sessionKey.isEmpty, !sessionKey.contains(where: { $0.isWhitespace || $0.isNewline }),
              !sessionKey.contains(";") else { throw AppFailure.invalidCredential }
        var request = URLRequest(url: URL(string: "https://claude.ai/api/account")!)
        request.httpMethod = "GET"; request.timeoutInterval = 15
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: ClaudeProfileRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppFailure.invalidCredential }
        try Self.verifyWebAccount(data: data, metadata: metadata)
    }
    public static func verifyWebAccount(data: Data, metadata: JSONValue) throws {
        let account = try JSONValue.parse(data)
        guard let expectedEmail = metadata["emailAddress"]?.string, !expectedEmail.isEmpty,
              let expectedOrg = metadata["organizationUuid"]?.string, !expectedOrg.isEmpty,
              let email = account["email_address"]?.string, email.lowercased() == expectedEmail.lowercased(),
              let memberships = account["memberships"]?.array,
              memberships.contains(where: { $0["organization"]?["uuid"]?.string == expectedOrg }) else { throw AppFailure.invalidCredential }
    }

    public func verify(token: String, metadata: JSONValue) async throws {
        try Self.validateToken(token)
        let data = try await profileFetcher(token)
        try Self.verifyProfile(data: data, metadata: metadata)
    }

    public static func fetchProfile(_ token: String) async throws -> Data {
        try validateToken(token)
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
            throw AppFailure.invalidCredential
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: ClaudeProfileRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AppFailure.message("Claude account identity could not be checked. Check connectivity and sign-in.") }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppFailure.message("Claude rejected the account identity check. Sign in again before switching.")
        }
        return data
    }

    public static func verifyProfile(data: Data, metadata: JSONValue) throws {
        let profile: JSONValue
        do { profile = try JSONValue.parse(data) } catch { throw AppFailure.invalidCredential }
        guard let account = profile["account"],
              let expectedEmail = metadata["emailAddress"]?.string, !expectedEmail.isEmpty,
              let expectedOrg = metadata["organizationUuid"]?.string, !expectedOrg.isEmpty,
              let organization = profile["organization"]?["uuid"]?.string,
              organization == expectedOrg else { throw AppFailure.invalidCredential }
        let emails = ["email", "email_address", "emailAddress"].compactMap { account[$0]?.string }
        guard !emails.isEmpty, emails.allSatisfy({ !$0.isEmpty && $0.lowercased() == expectedEmail.lowercased() }) else {
            throw AppFailure.invalidCredential
        }
    }
}
