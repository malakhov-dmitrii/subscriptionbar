import XCTest
@testable import SubscriptionCore

final class LocalizationCoreTests: XCTestCase {
    func testEveryModelTranslationHasBothCatalogEntries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/SubscriptionCore/Models.swift"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"L10n\.tr\("([^"]+)""#)
        let keys = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
            Range($0.range(at: 1), in: source).map { String(source[$0]) }
        }
        XCTAssertFalse(keys.isEmpty)
        for language in AppLanguage.allCases {
            let catalog = L10n.catalog(language)
            for key in keys { XCTAssertNotNil(catalog[key], "Missing \(language.rawValue): \(key)") }
        }
    }
    func testCoreCatalogsHaveMatchingKeysAndPlaceholders() {
        let english = L10n.catalog(.en)
        let russian = L10n.catalog(.ru)
        XCTAssertGreaterThan(english.count, 50)
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        for (key, value) in english {
            XCTAssertFalse(russian[key, default: ""].isEmpty, key)
            XCTAssertEqual(value.components(separatedBy: "%@").count, russian[key, default: ""].components(separatedBy: "%@").count, key)
        }
    }

    func testPersistedErrorTranslatesBothDirectionsWithoutChangingDetails() {
        let english = "Cannot inspect auth.json."
        let russian = "Не удалось проверить auth.json."
        XCTAssertEqual(L10n.translate(english, language: .ru), russian)
        XCTAssertEqual(L10n.translate(russian, language: .en), english)
        XCTAssertEqual(L10n.translate("custom account label", language: .ru), "custom account label")
    }

    func testVaultErrorAndRuntimeStatusTranslations() {
        XCTAssertEqual(L10n.translate("Vault is busy. Try again shortly.", language: .ru), "Хранилище занято. Повторите попытку чуть позже.")
        XCTAssertEqual(L10n.translate("Allow access", language: .ru), "Разрешить доступ")
        XCTAssertEqual(L10n.translate("Prepared 2 of 5. Old records will be preserved. Each click requests access at most once.", language: .ru), "Подготовлено 2 из 5. Старые записи сохранятся. Одно нажатие — не больше одного запроса доступа.")
    }
}
