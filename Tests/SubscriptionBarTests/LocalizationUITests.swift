import Testing
import Foundation
import SubscriptionCore
@testable import SubscriptionBar

@MainActor
struct LocalizationUITests {
    @Test func catalogsCoverBothLanguagesAndPreserveFormats() throws {
        let en = L10n.catalog(.en, table: "UI")
        let ru = L10n.catalog(.ru, table: "UI")
        #expect(en.count > 80)
        #expect(Set(en.keys) == Set(ru.keys))
        let token = try NSRegularExpression(pattern: "%(@|d|%)")
        for key in en.keys {
            let english = try #require(en[key])
            let russian = try #require(ru[key])
            func formats(_ text: String) -> [String] {
                token.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            }
            #expect(formats(english) == formats(russian))
        }
        #expect(L10n.translate("Осталось 77%", language: .en) == "77% remaining")
        #expect(L10n.translate("Added Claude: My account.", language: .ru) == "Добавлен Claude: My account.")
    }

    @Test func languageSettingSurvivesCodingAndOldSettingsRemainCompatible() throws {
        var settings = Settings()
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).language == nil)
        settings.language = .en
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).language == .en)
    }
}
