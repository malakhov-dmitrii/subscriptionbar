import Foundation

/// One rendered menu bar item: the abbreviation, its value and how urgent it is.
public struct MenuBarEntry: Sendable, Equatable, Identifiable {
    public let provider: Provider
    public let label: String
    public let value: String
    public let level: UsageLevel
    public var id: String { provider.rawValue }
    /// The menu bar is rendered as a template image, so colour cannot mark the
    /// service that is running out. A leading "!" survives monochrome.
    public var text: String { (level == .critical ? "!" : "") + label + value }
    public init(provider: Provider, label: String, value: String, level: UsageLevel) {
        self.provider = provider; self.label = label; self.value = value; self.level = level
    }
}

public enum MenuBarSummary {
    public static func value(_ snapshot: UsageSnapshot?, failed: Bool, now: Date) -> String {
        guard !failed, let snapshot, snapshot.isFresh(at: now) else { return "—" }
        if let remaining = snapshot.remainingPercent { return "\(Int(remaining.rounded(.down)))%" }
        return snapshot.balances.map { balance in
            let amount = String(format: "%.2f", locale: L10n.locale, balance.available)
            switch balance.currency.uppercased() {
            case "USD": return "$" + amount
            case "CNY": return "¥" + amount
            case "EUR": return "€" + amount
            default: return balance.currency + " " + amount
            }
        }.joined(separator: "/")
    }

    public static func label(_ provider: Provider) -> String {
        switch provider {
        case .claude: "C"
        case .codex: "X"
        case .grok: "G"
        case .zai: "Z"
        case .openCodeGo: "Go"
        case .kimiCode: "K"
        case .cursor: "Cu"
        case .openRouter: "OR"
        case .deepSeek: "D"
        }
    }

    /// Severity for one active account, so the icon and the text agree.
    public static func level(_ snapshot: UsageSnapshot?, failed: Bool, account: Account?,
                             settings: Settings, now: Date) -> UsageLevel {
        guard !failed, let snapshot, snapshot.isFresh(at: now) else { return .stale }
        if let account, account.provider.usesBalance {
            return RotationPolicy.exhausted(snapshot, account: account, threshold: settings.switchAt) ? .critical : .ok
        }
        return settings.level(snapshot.remainingPercent, stale: false)
    }
}
