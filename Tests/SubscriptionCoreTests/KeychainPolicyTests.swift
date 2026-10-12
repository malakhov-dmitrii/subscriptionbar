import XCTest
import LocalAuthentication
import Security
@testable import SubscriptionCore

final class KeychainPolicyTests: XCTestCase {
    func testBackgroundReadCannotOpenPasswordDialog() {
        let query = KeychainVault.readQuery(service: "fixture", account: "fixture")
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String)
    }
    func testBackgroundUpdateCannotOpenPasswordDialog() {
        let query = KeychainVault.writeQuery(service: "fixture", account: "fixture")
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String)
    }
    func testInteractiveReadRequiresExplicitOptIn() {
        let query = KeychainVault.readQuery(service: "fixture", account: "fixture", allowUserInteraction: true)
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, false)
        XCTAssertNil(query[kSecUseAuthenticationUI as String])
    }
    func testEachQueryGetsAFreshAuthenticationContext() {
        let first = KeychainVault.readQuery(service: "fixture", account: "fixture")
        let second = KeychainVault.readQuery(service: "fixture", account: "fixture")
        XCTAssertFalse((first[kSecUseAuthenticationContext as String] as? LAContext)
                       === (second[kSecUseAuthenticationContext as String] as? LAContext))
    }
}
