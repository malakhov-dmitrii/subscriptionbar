import Foundation
import SubscriptionCore

extension L10n {
    static func ui(_ key: String, _ args: CVarArg...) -> String {
        format(key, args: args, table: "UI")
    }
}

extension AppModel {
    /// Falls back to the language the catalogs are actually using, never a fixed one.
    var language: AppLanguage { settings.language ?? L10n.language }
    var locale: Locale { Locale(identifier: language == .ru ? "ru_RU" : "en_US") }
    func t(_ key: String, _ args: CVarArg...) -> String {
        L10n.format(key, args: args, table: "UI")
    }
    func message(_ text: String) -> String {
        text.components(separatedBy: "\n").map { L10n.translate($0) }.joined(separator: "\n")
    }
    func errorText(_ error: Error) -> String {
        if error is AppFailure || error is KeychainAccessError || error is VaultDataError {
            return error.localizedDescription
        }
        let technical = error as NSError
        return t("Operation failed (%@, code %d).", technical.domain, technical.code)
    }
    func accountLabel(_ account: Account) -> String {
        demo ? message(account.label) : account.label
    }
    func setLanguage(_ language: AppLanguage) {
        L10n.language = language
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        settings.language = language
        SubscriptionDelegate.updateWindowTitles()
        persist()
    }
    func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
    /// Freshness reads better as an age than as a wall clock time. `now` is taken
    /// from the caller's timeline so the label refreshes on the same tick.
    func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        guard seconds >= 60 else { return t("just now") }
        return Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .wide)
            .locale(locale)
            .format(date)
    }
    func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }
}
