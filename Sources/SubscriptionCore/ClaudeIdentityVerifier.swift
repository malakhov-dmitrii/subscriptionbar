import Foundation

private final class ClaudeProfileRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Verifies email and organization ownership, not the account UUID.
public struct ClaudeIdentityVerifier: Sendable {
    public init() {}
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
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else {
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
        try Self.verifyProfile(data: data, metadata: metadata)
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
