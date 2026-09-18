import Foundation
import XCTest
import Darwin
@testable import SubscriptionCore

final class SingleRecordVaultTests: XCTestCase {
    struct Call: Equatable, Sendable { let operation: String; let account: String; let interactive: Bool }
    final class Raw: RawVaultStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]
        private var recorded: [Call] = []
        private var denied = false
        var calls: [Call] { lock.withLock { recorded } }
        func seed(_ account: String, _ data: Data) { lock.withLock { items[account] = data } }
        func peek(_ account: String) -> Data? { lock.withLock { items[account] } }
        func deny() { lock.withLock { denied = true } }
        func read(service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
            try lock.withLock {
                recorded.append(Call(operation: "read", account: account, interactive: allowUserInteraction))
                if denied { throw KeychainAccessError(status: -128) }
                return items[account]
            }
        }
        func write(service: String, account: String, data: Data, allowUserInteraction: Bool) throws {
            try lock.withLock {
                recorded.append(Call(operation: "write", account: account, interactive: allowUserInteraction))
                if denied { throw KeychainAccessError(status: -128) }
                items[account] = data
            }
        }
    }
    struct Fixture {
        let raw = Raw()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SingleRecordVaultTests-\(UUID())")
        func vault(timeout: TimeInterval = 0.2) -> SingleRecordVault { SingleRecordVault(service: "test-only", root: root, raw: raw, lockTimeout: timeout) }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    func testAllBackgroundOperationsUseOneRecordWithoutInteractionOrLegacyFallback() throws {
        let f = Fixture(); defer { f.clean() }
        let legacy = Data("legacy".utf8)
        f.raw.seed("account:legacy", legacy)
        let vault = f.vault()
        XCTAssertEqual(vault.status(), .missing)
        XCTAssertNil(try vault.read("account:legacy"))
        try vault.write("account:new", data: Data("new".utf8))
        try vault.importEntries(["browser:one": Data("session".utf8), "account:two": Data("two".utf8)])
        XCTAssertEqual(vault.status(), .ready)
        XCTAssertEqual(try vault.read("account:two"), Data("two".utf8))
        try vault.remove("account:new")
        XCTAssertNil(try vault.read("account:new"))
        XCTAssertEqual(f.raw.peek("account:legacy"), legacy)
        XCTAssertTrue(f.raw.calls.allSatisfy { !$0.interactive && $0.account == "vault-v1" })
        let attributes = try FileManager.default.attributesOfItem(atPath: f.root.appendingPathComponent("vault-v1.lock").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testImportMergesInOneReadAndWrite() throws {
        let f = Fixture(); defer { f.clean() }
        try f.vault().importEntries(["a": Data([1]), "b": Data([2])])
        XCTAssertEqual(f.raw.calls.map(\.operation), ["read", "write"])
        try f.vault().importEntries(["c": Data([3])])
        XCTAssertEqual(try f.vault().read("a"), Data([1]))
        XCTAssertEqual(try f.vault().read("c"), Data([3]))
    }
    func testConflictingMigrationDoesNotOverwriteOrInsertAnyEntry() throws {
        let f = Fixture(); defer { f.clean() }
        let vault = f.vault()
        try vault.write("existing", data: Data([1]))
        let before = f.raw.peek("vault-v1")
        XCTAssertThrowsError(try vault.importEntries(["existing": Data([2]), "new": Data([3])]))
        XCTAssertEqual(f.raw.peek("vault-v1"), before)
        XCTAssertNil(try vault.read("new"))
        try vault.importEntries(["existing": Data([1]), "new": Data([3])])
        try vault.write("existing", data: Data([4]))
        XCTAssertEqual(try vault.read("existing"), Data([4]))
    }
    func testAuthorizeMakesOneInteractiveReadAndDoesNotAcquireFileLock() throws {
        let f = Fixture(); defer { f.clean() }
        try f.vault().write("a", data: Data([1]))
        let fd = open(f.root.appendingPathComponent("vault-v1.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let before = f.raw.calls.count
        XCTAssertTrue(try f.vault(timeout: 0).authorize())
        XCTAssertEqual(Array(f.raw.calls.dropFirst(before)), [Call(operation: "read", account: "vault-v1", interactive: true)])
        XCTAssertThrowsError(try f.vault(timeout: 0).write("b", data: Data([2])))
    }
    func testAuthorizationCancellationDoesNotRetryAndMissingDoesNotCreate() throws {
        let f = Fixture(); defer { f.clean() }
        XCTAssertFalse(try f.vault().authorize())
        XCTAssertNil(f.raw.peek("vault-v1"))
        f.raw.deny()
        let before = f.raw.calls.count
        XCTAssertThrowsError(try f.vault().authorize()) { XCTAssertTrue($0 is KeychainAccessError) }
        XCTAssertEqual(f.raw.calls.count - before, 1)
        XCTAssertEqual(f.vault().status(), .locked)
    }
    func testMalformedAndUnsupportedRecordsAreNotOverwritten() throws {
        for source in ["{}", "not-json", "{\"version\":2,\"entries\":{}}", "{\"version\":1,\"entries\":{\"a\":42}}"] {
            let f = Fixture(); defer { f.clean() }
            let original = Data(source.utf8); f.raw.seed("vault-v1", original)
            XCTAssertEqual(f.vault().status(), .invalid)
            XCTAssertThrowsError(try f.vault().read("a"))
            XCTAssertThrowsError(try f.vault().write("a", data: Data([1])))
            XCTAssertThrowsError(try f.vault().remove("a"))
            XCTAssertEqual(f.raw.peek("vault-v1"), original)
            XCTAssertFalse(f.raw.calls.contains { $0.operation == "write" })
        }
    }
    func testConcurrentVaultInstancesPreserveEveryEntry() async throws {
        let f = Fixture(); defer { f.clean() }
        let vault = f.vault(timeout: 2)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask { try vault.write("key-\(index)", data: Data([UInt8(index)])) }
            }
            try await group.waitForAll()
        }
        for index in 0..<24 { XCTAssertEqual(try vault.read("key-\(index)"), Data([UInt8(index)])) }
    }
    func testInteractionGateRestoresFailPolicyAndDoesNotQueueAnotherOperation() throws {
        final class Log: @unchecked Sendable {
            let lock = NSLock(); var flags: [Bool] = []
            func add(_ flag: Bool) { lock.withLock { flags.append(flag) } }
            func snapshot() -> [Bool] { lock.withLock { flags } }
        }
        let log = Log()
        let gate = KeychainInteractionGate { log.add($0) }
        XCTAssertThrowsError(try gate.perform(allowUserInteraction: true) {
            XCTAssertThrowsError(try gate.perform(allowUserInteraction: false) { XCTFail("Queued behind permission prompt") })
            throw KeychainAccessError(status: -128)
        })
        XCTAssertEqual(log.snapshot(), [true, false])
        try gate.perform(allowUserInteraction: false) {}
        XCTAssertEqual(log.snapshot(), [true, false, false, false])
    }
}
