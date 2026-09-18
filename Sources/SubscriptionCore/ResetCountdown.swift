import Foundation

public enum ResetCountdown {
    public static func text(until reset: Date, now: Date, language: AppLanguage, compact: Bool = false) -> String {
        let catalog = L10n.catalog(language, table: "UI")
        let locale = Locale(identifier: language == .ru ? "ru_RU" : "en_US")
        func format(_ key: String, _ args: CVarArg...) -> String {
            let template = catalog[key] ?? key
            return args.isEmpty ? template : String(format: template, locale: locale, arguments: args)
        }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return format("reset pending") }
        guard seconds >= 60 else { return compact ? format("<1m") : format("less than a minute") }
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append(format("%dd", days)) }
        if hours > 0 { parts.append(format("%dh", hours)) }
        if remainder > 0 { parts.append(format("%dm", remainder)) }
        let duration = (compact ? parts.map { $0.replacingOccurrences(of: " ", with: "") } : parts).joined(separator: " ")
        return compact ? duration : format("in %@", duration)
    }
}
