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
                if denied { throw KeychainAuthorizationError(target: .subscriptionVault, status: -25293) }
                return items[account]
            }
        }
        func write(service: String, account: String, data: Data, allowUserInteraction: Bool) throws {
            try lock.withLock {
                recorded.append(Call(operation: "write", account: account, interactive: allowUserInteraction))
                if denied { throw KeychainAuthorizationError(target: .subscriptionVault, status: -25293) }
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
    func testCompareAndSwapCreatesMissingKeyAndReplacesMatchingValue() throws {
        let f = Fixture(); defer { f.clean() }
        let vault: any SecretStoring = f.vault()
        try vault.compareAndSwap(key: "account:a", expected: nil, data: Data([1]))
        try vault.write("account:b", data: Data([9]))
        try vault.compareAndSwap(key: "account:a", expected: Data([1]), data: Data([2]))
        XCTAssertEqual(try vault.read("account:a"), Data([2]))
        XCTAssertEqual(try vault.read("account:b"), Data([9]))
        XCTAssertTrue(f.raw.calls.allSatisfy { !$0.interactive && $0.account == "vault-v1" })
    }
    func testCompareAndSwapRemovalAndMissingNoOpPreserveOtherEntries() throws {
        let f = Fixture(); defer { f.clean() }
        let vault = f.vault()
        try vault.compareAndSwap(key: "missing", expected: nil, data: nil)
        XCTAssertNil(f.raw.peek("vault-v1"))
        XCTAssertFalse(f.raw.calls.contains { $0.operation == "write" })
        try vault.importEntries(["a": Data([1]), "b": Data([2])])
        try vault.compareAndSwap(key: "a", expected: Data([1]), data: nil)
        XCTAssertNil(try vault.read("a"))
        XCTAssertEqual(try vault.read("b"), Data([2]))
    }
    func testKeychainVaultDelegatesCompareAndSwapWithoutSystemKeychainAccess() throws {
        let f = Fixture(); defer { f.clean() }
        let client = KeychainClient(snapshotReader: { selector, _, interactive in
            guard let data = try f.raw.read(service: selector.service, account: selector.account, allowUserInteraction: interactive) else { return nil }
            return KeychainItemSnapshot(selector: selector, persistentReference: Data([1]), data: data)
        }, writer: { selector, data in
            try f.raw.write(service: selector.service, account: selector.account, data: data, allowUserInteraction: false)
        })
        let vault: any SecretStoring = KeychainVault(service: "test-only", root: f.root, client: client)
        try vault.compareAndSwap(key: "a", expected: nil, data: Data([1]))
        XCTAssertThrowsError(try vault.compareAndSwap(key: "a", expected: nil, data: Data([2]))) {
            XCTAssertEqual($0 as? AppFailure, .concurrentChange)
        }
        XCTAssertEqual(try vault.read("a"), Data([1]))
        try vault.compareAndSwap(key: "a", expected: Data([1]), data: nil)
        XCTAssertNil(try vault.read("a"))
        XCTAssertTrue(f.raw.calls.allSatisfy { !$0.interactive && $0.account == "vault-v1" })
    }
    func testCompareAndSwapMismatchNeverChangesAnyEntry() throws {
        let f = Fixture(); defer { f.clean() }
        let vault = f.vault()
        try vault.importEntries(["a": Data([1]), "b": Data([2])])
        let before = f.raw.peek("vault-v1")
        let writes = f.raw.calls.filter { $0.operation == "write" }.count
        for expected in [nil, Data([9])] {
            for replacement in [nil, Data([3])] {
                XCTAssertThrowsError(try vault.compareAndSwap(key: "a", expected: expected, data: replacement)) {
                    XCTAssertEqual($0 as? AppFailure, .concurrentChange)
                }
            }
        }
        XCTAssertThrowsError(try vault.compareAndSwap(key: "missing", expected: Data([9]), data: Data([3]))) {
            XCTAssertEqual($0 as? AppFailure, .concurrentChange)
        }
        XCTAssertEqual(f.raw.peek("vault-v1"), before)
        XCTAssertEqual(f.raw.calls.filter { $0.operation == "write" }.count, writes)
    }
    func testCompareAndSwapAcquiresLockBeforeReadingAndPreservesLaterWriter() throws {
        let f = Fixture(); defer { f.clean() }
        let vault = f.vault(timeout: 0)
        try vault.importEntries(["a": Data([1]), "b": Data([2])])
        let fd = open(f.root.appendingPathComponent("vault-v1.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let before = f.raw.calls.count
        XCTAssertThrowsError(try vault.compareAndSwap(key: "a", expected: Data([1]), data: Data([3])))
        XCTAssertEqual(f.raw.calls.count, before, "CAS must not read before obtaining the same write lock")
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        try f.vault().write("a", data: Data([4]))
        XCTAssertThrowsError(try vault.compareAndSwap(key: "a", expected: Data([1]), data: Data([3]))) {
            XCTAssertEqual($0 as? AppFailure, .concurrentChange)
        }
        XCTAssertEqual(try vault.read("a"), Data([4]))
        XCTAssertEqual(try vault.read("b"), Data([2]))
    }
    func testCompetingCompareAndSwapsHaveOneWinnerAndKeepIndependentWrites() async throws {
        let f = Fixture(); defer { f.clean() }
        let vault = f.vault(timeout: 2)
        try vault.write("selected", data: Data([0]))
        let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 1...16 {
                group.addTask {
                    let other = SingleRecordVault(service: "test-only", root: f.root, raw: f.raw, lockTimeout: 2)
                    try other.write("other-\(index)", data: Data([UInt8(index)]))
                    do {
                        try other.compareAndSwap(key: "selected", expected: Data([0]), data: Data([UInt8(index)]))
                        return true
                    } catch AppFailure.concurrentChange { return false }
                }
            }
            var wins = 0
            for try await won in group { if won { wins += 1 } }
            return wins
        }
        XCTAssertEqual(wins, 1)
        XCTAssertNotEqual(try vault.read("selected"), Data([0]))
        for index in 1...16 { XCTAssertEqual(try vault.read("other-\(index)"), Data([UInt8(index)])) }
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
        XCTAssertThrowsError(try f.vault().authorize()) { XCTAssertTrue($0 is KeychainAuthorizationError) }
        XCTAssertEqual(f.raw.calls.count - before, 1)
        XCTAssertEqual(f.vault().status(), .authorizationRequired(
            KeychainAuthorizationError(target: .subscriptionVault, status: -25293)))
    }
    func testMalformedAndUnsupportedRecordsAreNotOverwritten() throws {
        for source in ["{}", "not-json", "{\"version\":2,\"entries\":{}}", "{\"version\":1,\"entries\":{\"a\":42}}"] {
            let f = Fixture(); defer { f.clean() }
            let original = Data(source.utf8); f.raw.seed("vault-v1", original)
            XCTAssertEqual(f.vault().status(), .invalid)
            XCTAssertThrowsError(try f.vault().read("a"))
            XCTAssertThrowsError(try f.vault().write("a", data: Data([1])))
            XCTAssertThrowsError(try f.vault().compareAndSwap(key: "a", expected: nil, data: Data([1])))
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
    func testPromptGateCoalescesNestedApprovalAndUnlocksAfterFailure() throws {
        let gate = KeychainPromptGate()
        XCTAssertThrowsError(try gate.perform {
            XCTAssertThrowsError(try gate.perform { XCTFail("Queued behind permission prompt") }) {
                XCTAssertTrue($0 is KeychainPromptInProgressError)
            }
            throw KeychainAccessError(status: -128)
        })
        XCTAssertNoThrow(try gate.perform {})
    }
}
