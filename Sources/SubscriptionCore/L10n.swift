import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case ru, en

    /// First launch follows the system, instead of assuming one of the two.
    public static var preferred: AppLanguage {
        let candidates = Locale.preferredLanguages + [Locale.current.identifier]
        return candidates.contains { $0.lowercased().hasPrefix("ru") } ? .ru : .en
    }
}

public enum L10n {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var language: AppLanguage = .en
    }
    private static let state = State()
    private static let catalogs: [String: [String: String]] = {
        var result: [String: [String: String]] = [:]
        for language in AppLanguage.allCases {
            for table in ["Core", "UI"] {
                result[language.rawValue + "/" + table] = loadCatalog(language, table: table)
            }
        }
        return result
    }()
    public static var language: AppLanguage {
        get { state.lock.withLock { state.language } }
        set { state.lock.withLock { state.language = newValue } }
    }
    public static var locale: Locale { Locale(identifier: language == .ru ? "ru_RU" : "en_US") }

    public static func tr(_ key: String, _ args: CVarArg..., table: String = "Core") -> String {
        format(key, args: args, table: table)
    }

    public static func format(_ key: String, args: [CVarArg], table: String = "Core") -> String {
        let value = catalog(language, table: table)[key] ?? key
        return args.isEmpty ? value : String(format: value, locale: locale, arguments: args)
    }

    public static func catalog(_ language: AppLanguage, table: String = "Core") -> [String: String] {
        catalogs[language.rawValue + "/" + table] ?? [:]
    }

    private static func loadCatalog(_ language: AppLanguage, table: String) -> [String: String] {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("SubscriptionBar_SubscriptionCore.bundle")
        let bundle = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let path = bundle.path(forResource: table, ofType: "strings", inDirectory: nil, forLocalization: language.rawValue),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return values
    }

    /// Re-localizes persisted messages without translating account names or protocol tokens.
    public static func translate(_ text: String) -> String {
        translate(text, language: language)
    }

    public static func translate(_ text: String, language: AppLanguage) -> String {
        for table in ["Core", "UI"] {
            let destination = catalog(language, table: table)
            if let exact = destination[text] { return exact }
            for sourceLanguage in AppLanguage.allCases {
                for (key, rawSource) in catalog(sourceLanguage, table: table) {
                    let source = rawSource.replacingOccurrences(of: "%%", with: "%")
                    guard let target = destination[key] else { continue }
                    if source == text { return target }
                    guard let tokens = try? NSRegularExpression(pattern: "%(@|lld|ld|d|lu|u|\\.[0-9]+f|f)") else { continue }
                    let sourceRange = NSRange(source.startIndex..., in: source)
                    let matches = tokens.matches(in: source, range: sourceRange)
                    guard !matches.isEmpty else { continue }
                    var pattern = "^"
                    var cursor = source.startIndex
                    for token in matches {
                        guard let range = Range(token.range, in: source) else { continue }
                        pattern += NSRegularExpression.escapedPattern(for: String(source[cursor..<range.lowerBound])) + "(.*?)"
                        cursor = range.upperBound
                    }
                    pattern += NSRegularExpression.escapedPattern(for: String(source[cursor...])) + "$"
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
                    let arguments = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
                    let targetTokens = tokens.matches(in: target, range: NSRange(target.startIndex..., in: target))
                    guard targetTokens.count == arguments.count else { continue }
                    var result = target
                    for (token, argument) in zip(targetTokens, arguments).reversed() {
                        guard let range = Range(token.range, in: result) else { continue }
                        result.replaceSubrange(range, with: argument)
                    }
                    return result.replacingOccurrences(of: "%%", with: "%")
                }
            }
        }
        return text
    }
}
