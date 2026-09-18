import Foundation

public struct UsageCredential: Sendable {
    public let provider: Provider
    public let bearer: String
    public let accountID: String?
    public let claudeSessionKey: String?
    public let claudeOrganizationID: String?

    public init(provider: Provider, bearer: String, accountID: String? = nil,
                claudeSessionKey: String? = nil, claudeOrganizationID: String? = nil) {
        self.provider = provider
        self.bearer = bearer
        self.accountID = accountID
        self.claudeSessionKey = claudeSessionKey
        self.claudeOrganizationID = claudeOrganizationID
    }
}

/// Refuses all redirects so authentication never follows a server-controlled destination.
private final class UsageRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct UsageAPI: Sendable {
    public init() {}

    public func fetch(_ credential: UsageCredential) async throws -> UsageSnapshot {
        let request = try Self.request(credential)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: UsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppFailure.message("\(credential.provider.name): usage request failed. Check connectivity and sign-in.")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if credential.provider == .claude && credential.claudeSessionKey == nil {
                throw AppFailure.message("Claude OAuth usage is unavailable. Connect a Claude browser session to read limits.")
            }
            throw AppFailure.message("\(credential.provider.name): usage service rejected the request. Check account access.")
        }
        return try Self.parse(provider: credential.provider, data: data,
                              source: request.url?.absoluteString ?? credential.provider.name)
    }

    static func request(_ credential: UsageCredential) throws -> URLRequest {
        let endpoint: String
        switch credential.provider {
        case .claude:
            if let key = credential.claudeSessionKey {
                guard !key.isEmpty, !key.contains(";"),
                      let org = credential.claudeOrganizationID, UUID(uuidString: org) != nil else {
                    throw AppFailure.invalidCredential
                }
                endpoint = "https://claude.ai/api/organizations/\(org)/usage"
            } else { endpoint = "https://api.anthropic.com/api/oauth/usage" }
        case .codex: endpoint = "https://chatgpt.com/backend-api/wham/usage"
        case .grok: endpoint = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
        case .zai: endpoint = "https://api.z.ai/api/monitor/usage/quota/limit"
        case .openCodeGo: endpoint = "https://opencode.ai/zen/go/v1/usage"
        case .kimiCode: endpoint = "https://api.kimi.com/coding/v1/usages"
        case .cursor: endpoint = "https://cursor.com/api/usage-summary"
        case .openRouter: endpoint = "https://openrouter.ai/api/v1/credits"
        case .deepSeek: endpoint = "https://api.deepseek.com/user/balance"
        }
        guard let url = URL(string: endpoint) else { throw AppFailure.invalidCredential }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let secret = credential.provider == .claude ? credential.claudeSessionKey ?? credential.bearer : credential.bearer
        guard !secret.isEmpty, !secret.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw AppFailure.invalidCredential
        }
        if credential.provider == .claude, let key = credential.claudeSessionKey {
            request.setValue("sessionKey=\(key)", forHTTPHeaderField: "Cookie")
        } else if credential.provider == .cursor {
            request.setValue(try CursorLocalAuth.cookieHeader(secret), forHTTPHeaderField: "Cookie")
        } else {
            request.setValue(credential.provider == .zai ? secret : "Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        switch credential.provider {
        case .claude:
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        case .codex:
            if let accountID = credential.accountID {
                guard !accountID.isEmpty, !accountID.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                    throw AppFailure.invalidCredential
                }
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        case .grok:
            request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")
            request.setValue("1.0.5", forHTTPHeaderField: "x-grok-client-version")
            request.setValue("grok-cli", forHTTPHeaderField: "x-grok-client-identifier")
            request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        case .zai: request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
        default: break
        }
        return request
    }

    public static func parse(provider: Provider, data: Data, source: String, now: Date = Date()) throws -> UsageSnapshot {
        if provider == .kimiCode { return try KimiCodeUsage.parse(data: data, source: source, now: now) }
        if provider == .cursor { return try CursorUsage.parse(data: data, source: source, now: now) }
        let root: JSONValue
        do { root = try JSONValue.parse(data) } catch { throw AppFailure.invalidUsage }
        guard root.object != nil else { throw AppFailure.invalidUsage }
        var windows: [UsageWindow] = []
        var balances: [Balance] = []
        switch provider {
        case .kimiCode, .cursor: throw AppFailure.invalidUsage
        case .claude:
            for (field, label) in [("five_hour", "5 hours"), ("seven_day", "7 days")] {
                guard let entry = root[field], entry != .null else { continue }
                windows.append(try UsageWindow(label, usedPercent: number(entry["utilization"]),
                                               resetsAt: isoDate(entry["resets_at"])))
            }
            let scopedFable = root["limits"]?.array?.filter { limit in
                guard limit["kind"]?.string == "weekly_scoped", let model = limit["scope"]?["model"] else { return false }
                let id = model["id"]?.string?.lowercased() ?? ""
                let name = model["display_name"]?.string?.lowercased() ?? ""
                return ["fable", "mythos"].contains { id.contains($0) || name == $0 }
            } ?? []
            if !scopedFable.isEmpty {
                for entry in scopedFable {
                    windows.append(try UsageWindow("Fable · 7 days", usedPercent: number(entry["percent"]), resetsAt: isoDate(entry["resets_at"])))
                }
            } else if let entry = root["seven_day_fable"], entry != .null {
                windows.append(try UsageWindow("Fable · 7 days", usedPercent: number(entry["utilization"]), resetsAt: isoDate(entry["resets_at"])))
            }
        case .codex:
            guard let rate = root["rate_limit"], rate.object != nil else { throw AppFailure.invalidUsage }
            for (field, label) in [("primary_window", "Primary"), ("secondary_window", "Weekly")] {
                guard let entry = rate[field], entry != .null else { continue }
                windows.append(try UsageWindow(label, usedPercent: number(entry["used_percent"]),
                                               resetsAt: epochDate(entry["reset_at"])))
            }
        case .grok:
            let config = root["config"] ?? root
            let reset = config["currentPeriod"]?["end"] ?? config["billingPeriodEnd"]
            let used: Double
            if let percent = config["creditUsagePercent"] {
                used = try number(percent)
            } else {
                // Protobuf JSON omits a zero scalar after the weekly reset.
                // Require a complete current period before interpreting the omission.
                guard config["currentPeriod"]?["type"]?.string == "USAGE_PERIOD_TYPE_WEEKLY",
                      let start = try isoDate(config["currentPeriod"]?["start"]),
                      let end = try isoDate(config["currentPeriod"]?["end"]),
                      start <= now, now < end,
                      config["productUsage"] == nil else { throw AppFailure.invalidUsage }
                used = 0
            }
            windows.append(try UsageWindow("Credits", usedPercent: used,
                                           resetsAt: isoDate(reset)))
        case .zai:
            guard let entries = root["data"]?["limits"]?.array else { throw AppFailure.invalidUsage }
            for entry in entries where entry["type"]?.string == "TOKENS_LIMIT" {
                windows.append(try UsageWindow("5 hours", usedPercent: number(entry["percentage"])))
            }
        case .openCodeGo:
            guard let usage = root["usage"], usage.object != nil else { throw AppFailure.invalidUsage }
            for (field, label) in [("rolling", "5 hours"), ("weekly", "Weekly"), ("monthly", "Monthly")] {
                guard let entry = usage[field],
                      let status = entry["status"]?.string, ["ok", "rate-limited"].contains(status),
                      let reset = try isoDate(entry["resetsAt"]) else { throw AppFailure.invalidUsage }
                let percent = try number(entry["percent"])
                guard status != "rate-limited" || percent == 100 else { throw AppFailure.invalidUsage }
                windows.append(try UsageWindow(label, usedPercent: percent, resetsAt: reset))
            }
        case .openRouter:
            let credits = try number(root["data"]?["total_credits"])
            let usage = try number(root["data"]?["total_usage"])
            guard credits >= 0, usage >= 0 else { throw AppFailure.invalidUsage }
            balances.append(try Balance(currency: "USD", available: credits - usage))
        case .deepSeek:
            guard root["is_available"]?.bool != nil,
                  let entries = root["balance_infos"]?.array else { throw AppFailure.invalidUsage }
            var currencies = Set<String>()
            for entry in entries {
                guard let currency = entry["currency"]?.string, ["USD", "CNY"].contains(currency),
                      currencies.insert(currency).inserted else { throw AppFailure.invalidUsage }
                balances.append(try Balance(currency: currency, available: number(entry["total_balance"])))
            }
        }
        return try UsageSnapshot(windows: windows, balances: balances, source: source, fetchedAt: now)
    }

    private static func number(_ value: JSONValue?) throws -> Double {
        guard let number = value?.number, number.isFinite else { throw AppFailure.invalidUsage }
        return number
    }

    private static func isoDate(_ value: JSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        guard let string = value.string else { throw AppFailure.invalidUsage }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: string) else { throw AppFailure.invalidUsage }
        return date
    }

    private static func epochDate(_ value: JSONValue?) throws -> Date? {
        guard let value, value != .null else { return nil }
        let seconds = try number(value)
        guard seconds > 0, seconds < 253_402_300_800 else { throw AppFailure.invalidUsage }
        return Date(timeIntervalSince1970: seconds)
    }
}
