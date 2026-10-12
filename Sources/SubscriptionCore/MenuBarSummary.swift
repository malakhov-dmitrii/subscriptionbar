import Foundation

/// One limit window on its own line, named so the number always has a meaning.
public struct MenuBarRow: Sendable, Equatable {
    public let window: String
    public let spokenWindow: String
    public let value: String
    public var text: String { window + " " + value }
    public init(window: String, spokenWindow: String, value: String) {
        self.window = window; self.spokenWindow = spokenWindow; self.value = value
    }
}

/// One rendered menu bar item: the abbreviation, its value and how urgent it is.
/// When `rows` is not empty they replace `value` and are drawn one above the other.
public struct MenuBarEntry: Sendable, Equatable, Identifiable {
    public let provider: Provider
    public let label: String
    public let value: String
    public let rows: [MenuBarRow]
    public let level: UsageLevel
    /// The numbers are the last reading while the service asks to slow down.
    public let delayed: Bool
    public var id: String { provider.rawValue }
    /// The menu bar is rendered as a template image, so colour cannot mark the
    /// service that is running out. A leading "!" survives monochrome.
    public var marker: String { level == .critical ? "!" : "" }
    public var text: String {
        rows.isEmpty ? marker + label + value : ([marker + label] + rows.map(\.text)).joined(separator: " ")
    }
    public init(provider: Provider, label: String, value: String, rows: [MenuBarRow] = [], level: UsageLevel,
                delayed: Bool = false) {
        self.provider = provider; self.label = label; self.value = value; self.rows = rows; self.level = level
        self.delayed = delayed
    }
}

public enum MenuBarSummary {
    /// The lowest remaining limit swaps between the session and the week after
    /// every reset, so a plan with both shows each in a fixed, labelled row.
    /// Other windows stay out of the menu bar; they still drive `level`.
    public static func rows(_ snapshot: UsageSnapshot?, failed: Bool, paced: Bool = false, now: Date) -> [MenuBarRow] {
        guard let snapshot,
              let session = snapshot.windows.first(where: { $0.name == "5 hours" }),
              let week = snapshot.windows.first(where: { ["7 days", "Weekly"].contains($0.name) }) else { return [] }
        let visible = ReadingFreshness.state(snapshot, failed: failed, paced: paced, now: now) != .unavailable
        func row(_ window: UsageWindow, short: String) -> MenuBarRow {
            MenuBarRow(window: L10n.tr(short, table: "UI"), spokenWindow: L10n.tr(window.name, table: "UI"),
                       value: visible ? "\(Int(window.remaining.rounded(.down)))%" : "—")
        }
        return [row(session, short: "5h"), row(week, short: "wk")]
    }

    public static func value(_ snapshot: UsageSnapshot?, failed: Bool, paced: Bool = false, now: Date) -> String {
        guard let snapshot, ReadingFreshness.state(snapshot, failed: failed, paced: paced, now: now) != .unavailable else { return "—" }
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
    public static func level(_ snapshot: UsageSnapshot?, failed: Bool, paced: Bool = false, account: Account?,
                             settings: Settings, now: Date) -> UsageLevel {
        guard let snapshot, ReadingFreshness.state(snapshot, failed: failed, paced: paced, now: now) != .unavailable else { return .stale }
        if let account, account.provider.usesBalance {
            return RotationPolicy.exhausted(snapshot, account: account, threshold: settings.switchAt) ? .critical : .ok
        }
        return settings.level(snapshot.remainingPercent, stale: false)
    }
}
