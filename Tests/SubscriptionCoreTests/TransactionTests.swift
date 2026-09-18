import XCTest
@testable import SubscriptionCore

final class TransactionTests: XCTestCase {
    final class Cell {
        var value: Data?; var fail = false
        init(_ value: String) { self.value = Data(value.utf8) }
        func mutation(_ target: String) -> Mutation {
            Mutation(name: "test", before: value, after: Data(target.utf8), read: { self.value }, replace: { data, expected in
                guard self.value == expected else { throw AppFailure.concurrentChange }
                if self.fail { throw AppFailure.message("Injected write failure") }
                self.value = data
            })
        }
    }
    func testPartialFailureRestoresPreviousCredential() {
        let a = Cell("old-a"), b = Cell("old-b"); b.fail = true
        XCTAssertThrowsError(try CredentialTransaction.perform([a.mutation("new-a"), b.mutation("new-b")], verify: {}))
        XCTAssertEqual(a.value, Data("old-a".utf8)); XCTAssertEqual(b.value, Data("old-b".utf8))
    }
    func testIdentityMismatchRollsBack() {
        let a = Cell("old")
        XCTAssertThrowsError(try CredentialTransaction.perform([a.mutation("new")], verify: { throw AppFailure.invalidCredential }))
        XCTAssertEqual(a.value, Data("old".utf8))
    }
    func testDoesNotOverwriteConcurrentChangeOnRollback() {
        let a = Cell("old")
        XCTAssertThrowsError(try CredentialTransaction.perform([a.mutation("new")], verify: {
            a.value = Data("external-login".utf8); throw AppFailure.invalidCredential
        }))
        XCTAssertEqual(a.value, Data("external-login".utf8))
    }
    func testPreflightDoesNotWriteAnyDestination() {
        let a = Cell("a"), b = Cell("b"); let mutations = [a.mutation("new-a"), b.mutation("new-b")]
        b.value = Data("external".utf8)
        XCTAssertThrowsError(try CredentialTransaction.perform(mutations, verify: {}))
        XCTAssertEqual(a.value, Data("a".utf8))
    }
    func testAtomicFileWritePermissionsAndSymlinkRejection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("auth.json")
        try SecureFiles.write(Data("old".utf8), to: path, expected: nil)
        try CredentialTransaction.perform([Mutation.file(path, after: Data("new".utf8))], verify: {})
        XCTAssertEqual(try SecureFiles.read(path), Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try SecureFiles.read(link))
    }
}
