import Foundation

private final class OAuthRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Refreshes a managed snapshot only. Caller owns serialization and compare-and-swap persistence.
/// Sources: Claude tracker ClaudeCodeSyncService/CodexAuthService; grok-usage AuthStore.
public struct OAuthRefresher: Sendable {
    public init() {}

    public func refreshIfNeeded(_ envelope: CredentialEnvelope, provider: Provider,
                                force: Bool = false) async throws -> CredentialEnvelope {
        guard let request = try Self.prepare(envelope, provider: provider, force: force) else { return envelope }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: OAuthRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AppFailure.message("Token refresh outcome is unknown. Do not retry automatically; sign in again if needed.") }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppFailure.message("Token refresh was not accepted. Sign in again in the original client.")
        }
        // A successful fixed-TLS OAuth refresh is bound to the existing refresh principal.
        // Opaque Claude tokens retain that original association; they do not independently
        // prove an account UUID. merge rejects contradictory parseable JWT claims.
        // Return immediately so the caller can persist rotated credentials with CAS before
        // any optional profile/usage call that could fail and discard the new refresh token.
        return try Self.merge(data: data, into: envelope, provider: provider)
    }

    public static func prepare(_ envelope: CredentialEnvelope, provider: Provider,
                               force: Bool = false, now: Date = Date()) throws -> URLRequest? {
        guard provider.hasCLIProfile, !envelope.primary.isEmpty else { return nil }
        guard try CredentialParser.parse(provider: provider, data: envelope.primary, metadata: envelope.metadata).identity == envelope.identity else {
            throw AppFailure.invalidCredential
        }
        let root = try JSONValue.parse(envelope.primary)
        let endpoint: String
        let refresh: String?
        let client: String
        let expires: Date?
        switch provider {
        case .claude:
            endpoint = "https://platform.claude.com/v1/oauth/token"
            client = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            refresh = root["claudeAiOauth"]?["refreshToken"]?.string
            if let milliseconds = root["claudeAiOauth"]?["expiresAt"]?.number,
               milliseconds.isFinite, milliseconds > 0 {
                expires = Date(timeIntervalSince1970: milliseconds / 1000)
            } else { expires = nil }
        case .codex:
            endpoint = "https://auth.openai.com/oauth/token"
            client = "app_EMoamEEZ73f0CkXaXp7hrann"
            refresh = root["tokens"]?["refresh_token"]?.string
            expires = jwtExpiry(root["tokens"]?["access_token"]?.string)
        case .grok:
            endpoint = "https://auth.x.ai/oauth2/token"
            guard let (key, record) = grokEntry(root) else { throw AppFailure.invalidCredential }
            refresh = record["refresh_token"]?.string
            let fromKey = key.range(of: "::", options: .backwards).map { String(key[$0.upperBound...]) }
            guard let id = record["oidc_client_id"]?.string ?? fromKey, !id.isEmpty else { throw AppFailure.invalidCredential }
            client = id
            expires = isoDate(record["expires_at"]?.string)
        default: return nil
        }
        if !force, let expires, expires.timeIntervalSince(now) > 300 { return nil }
        guard let refresh, !refresh.isEmpty, let url = URL(string: endpoint) else {
            throw AppFailure.message("This saved login needs to be renewed in the original client.")
        }
        var fields = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .codex {
            fields["scope"] = "openid profile email"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(fields)
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            request.httpBody = Data(try fields.keys.sorted().map { key in
                guard let value = fields[key], let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                    throw AppFailure.invalidCredential
                }
                return key + "=" + encoded
            }.joined(separator: "&").utf8)
        }
        return request
    }

    public static func merge(data: Data, into envelope: CredentialEnvelope, provider: Provider,
                             now: Date = Date()) throws -> CredentialEnvelope {
        guard var root = try JSONValue.parse(envelope.primary).object,
              let response = try JSONValue.parse(data).object,
              let access = response["access_token"]?.string, !access.isEmpty else { throw AppFailure.invalidCredential }
        for field in ["refresh_token", "id_token"] {
            if let value = response[field], value.string?.isEmpty != false { throw AppFailure.invalidCredential }
        }
        switch provider {
        case .claude:
            guard var record = root["claudeAiOauth"]?.object else { throw AppFailure.invalidCredential }
            record["accessToken"] = .string(access)
            if let refresh = response["refresh_token"] { record["refreshToken"] = refresh }
            record["expiresAt"] = .number(try expiration(response, now: now).timeIntervalSince1970 * 1000)
            root["claudeAiOauth"] = .object(record)
        case .codex:
            guard var record = root["tokens"]?.object,
                  let expiry = jwtExpiry(access), expiry > now else { throw AppFailure.invalidCredential }
            record["access_token"] = .string(access)
            for field in ["refresh_token", "id_token"] { if let value = response[field] { record[field] = value } }
            root["tokens"] = .object(record)
            root["last_refresh"] = .string(ISO8601DateFormatter().string(from: now))
        case .grok:
            guard let (key, original) = grokEntry(.object(root)), var record = original.object else { throw AppFailure.invalidCredential }
            record["key"] = .string(access)
            if let refresh = response["refresh_token"] { record["refresh_token"] = refresh }
            record["expires_at"] = .string(ISO8601DateFormatter().string(from: try expiration(response, now: now)))
            root[key] = .object(record)
        default: throw AppFailure.invalidCredential
        }
        let primary = try JSONValue.object(root).data()
        let parsed = try CredentialParser.parse(provider: provider, data: primary, metadata: envelope.metadata)
        guard parsed.identity == envelope.identity else { throw AppFailure.invalidCredential }
        var updated = envelope
        updated.primary = primary
        return updated
    }

    private static func expiration(_ response: [String: JSONValue], now: Date) throws -> Date {
        guard let seconds = response["expires_in"]?.number, seconds.isFinite, seconds > 0, seconds < 31_536_000 else {
            throw AppFailure.invalidCredential
        }
        return now.addingTimeInterval(seconds)
    }
    private static func jwtExpiry(_ token: String?) -> Date? {
        guard let token, let seconds = CredentialParser.jwt(token)?["exp"]?.number,
              seconds.isFinite, seconds > 0, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    private static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    private static func grokEntry(_ root: JSONValue) -> (String, JSONValue)? {
        let entries = root.object?.filter { $0.value["key"]?.string?.isEmpty == false } ?? [:]
        guard entries.count == 1, let entry = entries.first else { return nil }
        return (entry.key, entry.value)
    }
}
