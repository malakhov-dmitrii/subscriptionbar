import XCTest
@testable import SubscriptionCore

final class OpenCodeConnectionTests: XCTestCase {
    func testLocalClientCredentialUsesOnlyGoEntry() throws {
        let data = Data(#"{"openai":{"type":"api","key":"unrelated"},"opencode-go":{"type":"api","key":"fixture-go-key"}}"#.utf8)
        let result = try OpenCodeKeyImport.credential(data)
        XCTAssertEqual(result.primary, Data("fixture-go-key".utf8))
        XCTAssertThrowsError(try OpenCodeKeyImport.credential(Data(#"{"opencode":{"type":"api","key":"zen-key"}}"#.utf8)))
    }
    func testAPIRejectionIsTranslatedExactly() {
        XCTAssertEqual(L10n.translate("OpenCode Go: usage service rejected the request. Check account access.", language: .ru), "OpenCode Go: сервис отклонил запрос лимитов. Проверьте доступ к аккаунту.")
    }
}
