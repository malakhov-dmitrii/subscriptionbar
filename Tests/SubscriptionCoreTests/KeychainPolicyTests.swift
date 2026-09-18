import XCTest
import Security
@testable import SubscriptionCore

final class KeychainPolicyTests: XCTestCase {
    func testBackgroundReadCannotOpenPasswordDialog() {
        let query = KeychainVault.readQuery(service: "fixture", account: "fixture")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
    }
    func testBackgroundUpdateCannotOpenPasswordDialog() {
        let query = KeychainVault.writeQuery(service: "fixture", account: "fixture")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
    }
    func testInteractiveReadRequiresExplicitOptIn() {
        let query = KeychainVault.readQuery(service: "fixture", account: "fixture", allowUserInteraction: true)
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }
}
