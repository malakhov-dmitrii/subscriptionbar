import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, grok, zai, openCodeGo, kimiCode, cursor, openRouter, deepSeek
    public var id: String { rawValue }
    /// One name per service everywhere: menu bar abbreviation aside, the dashboard,
    /// the settings lists and the add-account picker must not invent variants.
    public var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT / Codex"
        case .grok: "Grok"
        case .zai: "Z.ai"
        case .openCodeGo: "OpenCode Go"
        case .kimiCode: "Kimi Code"
        case .cursor: "Cursor"
        case .openRouter: "OpenRouter"
        case .deepSeek: "DeepSeek"
        }
    }
    public var usesBalance: Bool { self == .openRouter || self == .deepSeek }
    public var hasCLIProfile: Bool { [.claude, .codex, .grok].contains(self) }
    public var website: URL {
        let address: String
        switch self {
        case .claude: address = "https://claude.ai/settings/usage"
        case .codex: address = "https://chatgpt.com/codex/settings/usage"
        case .grok: address = "https://grok.com/?_s=billing"
        case .zai: address = "https://z.ai/manage-apikey/subscription"
        case .openCodeGo: address = "https://opencode.ai/go"
        case .kimiCode: address = "https://www.kimi.com/code/console"
        case .cursor: address = "https://cursor.com/dashboard"
        case .openRouter: address = "https://openrouter.ai/settings/credits"
        case .deepSeek: address = "https://platform.deepseek.com/usage"
        }
        return URL(string: address)!
    }
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var identity: String
    public var browserEnabled: Bool
    public var enabled: Bool
    public var balanceThreshold: Double
    public var monitoringOnly: Bool?
    public init(id: UUID = UUID(), provider: Provider, label: String, identity: String,
                browserEnabled: Bool = false, enabled: Bool = true, balanceThreshold: Double = 1) {
        self.id = id; self.provider = provider; self.label = label; self.identity = identity
        self.browserEnabled = browserEnabled; self.enabled = enabled; self.balanceThreshold = balanceThreshold
    }
    public var canSwitch: Bool { provider.hasCLIProfile && monitoringOnly != true }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public var name: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public init(_ name: String, usedPercent: Double, resetsAt: Date? = nil) throws {
        guard usedPercent.isFinite, usedPercent >= 0, usedPercent <= 100 else { throw AppFailure.invalidUsage }
        self.name = name; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
    public var remaining: Double { 100 - usedPercent }
}

public struct Balance: Codable, Equatable, Sendable {
    public var currency: String
    public var available: Double
    public init(currency: String, available: Double) throws {
        guard available.isFinite, !currency.isEmpty else { throw AppFailure.invalidUsage }
        self.currency = currency; self.available = available
    }
}

/// Shared severity so the compact row, the expanded card and the menu bar
/// never disagree about what counts as low.
public enum UsageLevel: Sendable, Equatable {
    case ok, warning, critical, stale

    public static func of(remaining: Double?, stale: Bool, warnAt: Double, criticalAt: Double) -> UsageLevel {
        if stale { return .stale }
        guard let remaining else { return .ok }
        if remaining <= criticalAt { return .critical }
        if remaining <= warnAt { return .warning }
        return .ok
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var windows: [UsageWindow]
    public var balances: [Balance]
    public var source: String
    public init(windows: [UsageWindow] = [], balances: [Balance] = [], source: String, fetchedAt: Date = Date()) throws {
        guard !windows.isEmpty || !balances.isEmpty else { throw AppFailure.invalidUsage }
        self.windows = windows; self.balances = balances; self.source = source; self.fetchedAt = fetchedAt
    }
    public var remainingPercent: Double? { windows.map(\.remaining).min() }
    public func isFresh(at now: Date, maxAge: TimeInterval = 90) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= maxAge && !windows.contains { ($0.resetsAt ?? .distantFuture) <= now }
    }
}

public struct Settings: Codable, Sendable {
    public var accounts: [Account] = []
    public var active: [Provider: UUID] = [:]
    public var enabledProviders: Set<Provider> = [.claude, .codex, .grok]
    public var autoSwitch = true
    public var restartCodex = true
    /// Percent remaining that triggers rotation. Older settings files decode as nil.
    public var switchThreshold: Double?
    /// Percent remaining that turns the interface orange before rotation happens.
    public var warnThreshold: Double?
    public var claudeHome = "~/.claude"
    public var codexHome = "~/.codex"
    public var grokHome = "~/.grok"
    public var lastSwitch: [Provider: Date] = [:]
    public var automationPausedReason: String?
    public var vaultSetupComplete: Bool?
    public var menuBarProviders: Set<Provider>?
    public var language: AppLanguage?
    public init() {}

    public var switchAt: Double { switchThreshold ?? 1 }
    public var warnAt: Double { max(warnThreshold ?? 15, switchAt) }
    public func level(_ remaining: Double?, stale: Bool) -> UsageLevel {
        UsageLevel.of(remaining: remaining, stale: stale, warnAt: warnAt, criticalAt: switchAt)
    }
}

public enum AppFailure: Error, LocalizedError, Equatable {
    case invalidUsage, invalidCredential, missingCredential, concurrentChange, unsupported(String), message(String)
    public var errorDescription: String? {
        switch self {
        case .invalidUsage: L10n.tr("Usage response is missing, invalid, or has an unknown format.")
        case .invalidCredential: L10n.tr("Cannot verify the account in these credentials. Sign in again in the original client.")
        case .missingCredential: L10n.tr("No saved credentials. Sign in in the original client, then capture the account.")
        case .concurrentChange: L10n.tr("The client changed its credentials during the operation. No automatic retry was made.")
        case .unsupported(let value), .message(let value): L10n.translate(value)
        }
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? { object?[key] }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? {
        switch self { case .number(let v): v; case .string(let v): Double(v); default: nil }
    }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
