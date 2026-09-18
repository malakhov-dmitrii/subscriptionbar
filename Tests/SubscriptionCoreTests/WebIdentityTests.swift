import XCTest
@testable import SubscriptionCore

final class WebIdentityTests: XCTestCase {
    func testSameOrganizationDoesNotMakeDifferentUsersEquivalent() throws {
        let metadata: JSONValue = .object(["emailAddress": .string("owner@example.test"), "organizationUuid": .string("org")])
        let foreign = Data(#"{"email_address":"other@example.test","memberships":[{"organization":{"uuid":"org"}}]}"#.utf8)
        XCTAssertThrowsError(try ClaudeIdentityVerifier.verifyWebAccount(data: foreign, metadata: metadata))
        let matching = Data(#"{"email_address":"OWNER@example.test","memberships":[{"organization":{"uuid":"org"}}]}"#.utf8)
        XCTAssertNoThrow(try ClaudeIdentityVerifier.verifyWebAccount(data: matching, metadata: metadata))
        let otherOrg = Data(#"{"email_address":"owner@example.test","memberships":[{"organization":{"uuid":"other"}}]}"#.utf8)
        XCTAssertThrowsError(try ClaudeIdentityVerifier.verifyWebAccount(data: otherOrg, metadata: metadata))
    }
}
