import Foundation
import Testing
@testable import SubscriptionCore

struct KeychainRecoveryFlowTests {
    final class Recorder: @unchecked Sendable {
        struct Call: Equatable { let interactive: Bool; let persistent: Bool }
        let lock = NSLock()
        var calls: [Call] = []
        var snapshots: [KeychainItemSnapshot?] = []
        var failure: Error?
        var writes = 0
        func read(_ selector: KeychainItemSelector, _ persistent: Data?, _ interactive: Bool) throws -> KeychainItemSnapshot? {
            try lock.withLock {
                calls.append(Call(interactive: interactive, persistent: persistent != nil))
                if let failure { throw failure }
                return snapshots.isEmpty ? nil : snapshots.removeFirst()
            }
        }
        func recordWrite() { lock.withLock { writes += 1 } }
        var writeCount: Int { lock.withLock { writes } }
    }

    let selector = KeychainItemSelector(service: "fixture", account: "current-user")

    @Test func authorizationUsesOneInteractiveReadThenPersistentNoUIReadBack() throws {
        let recorder = Recorder()
        let reference = Data("persistent".utf8)
        recorder.snapshots = [
            KeychainItemSnapshot(selector: selector, persistentReference: reference, data: Data("identity-A".utf8)),
            KeychainItemSnapshot(selector: selector, persistentReference: reference, data: Data("identity-A".utf8))
        ]
        let client = KeychainClient(snapshotReader: recorder.read, writer: { _, _ in Issue.record("Recovery wrote Keychain data") })

        #expect(try client.authorizeAndVerify(selector) { String(decoding: $0, as: UTF8.self) } == .verified)
        #expect(recorder.calls == [
            .init(interactive: true, persistent: false),
            .init(interactive: false, persistent: true)
        ])
    }

    @Test func changedPersistentItemOrIdentityNeverVerifies() throws {
        let first = Data("first".utf8), second = Data("second".utf8)
        for snapshots in [
            [KeychainItemSnapshot(selector: selector, persistentReference: first, data: Data("A".utf8)),
             KeychainItemSnapshot(selector: selector, persistentReference: second, data: Data("A".utf8))],
            [KeychainItemSnapshot(selector: selector, persistentReference: first, data: Data("A".utf8)),
             KeychainItemSnapshot(selector: selector, persistentReference: first, data: Data("B".utf8))]
        ] {
            let recorder = Recorder(); recorder.snapshots = snapshots
            let client = KeychainClient(snapshotReader: recorder.read, writer: { _, _ in })
            #expect(try client.authorizeAndVerify(selector) { String(decoding: $0, as: UTF8.self) } == .changed)
        }
    }

    @Test func missingAndMalformedItemsDoNotCreateOrWriteAnything() throws {
        let missing = Recorder(); missing.snapshots = [nil]
        let missingClient = KeychainClient(snapshotReader: missing.read, writer: { [missing] _, _ in missing.recordWrite() })
        #expect(try missingClient.authorizeAndVerify(selector) { _ in "unused" } == .missing)

        let malformed = Recorder()
        let reference = Data("persistent".utf8)
        malformed.snapshots = [
            KeychainItemSnapshot(selector: selector, persistentReference: reference, data: Data()),
            KeychainItemSnapshot(selector: selector, persistentReference: reference, data: Data())
        ]
        let malformedClient = KeychainClient(snapshotReader: malformed.read,
                                             writer: { [malformed] _, _ in malformed.recordWrite() })
        #expect(try malformedClient.authorizeAndVerify(selector) { _ in throw AppFailure.invalidCredential } == .invalid)
        #expect(missing.writeCount == 0)
        #expect(malformed.writeCount == 0)
    }

    @Test func onlyRecoverableBackgroundFailuresCreateTypedAuthorization() throws {
        let target = KeychainAuthorizationTarget.claudeCode(selector)
        for status in [Int32(-25293), Int32(-25308), Int32(-25315)] {
            let client = KeychainClient(snapshotReader: { _, _, _ in throw KeychainAccessError(status: status) },
                                        writer: { _, _ in })
            #expect(throws: KeychainAuthorizationError.self) { try client.read(selector, target: target) }
        }
        let decode = KeychainClient(snapshotReader: { _, _, _ in throw KeychainAccessError(status: -26275) },
                                    writer: { _, _ in })
        #expect(throws: KeychainAccessError.self) { try decode.read(selector, target: target) }
        let cancel = KeychainClient(snapshotReader: { _, _, _ in throw KeychainAccessError(status: -128) },
                                    writer: { _, _ in })
        #expect(throws: KeychainAccessError.self) {
            try cancel.read(selector, target: target, allowUserInteraction: true)
        }
    }

    @Test func ownVaultFailureCannotBeConfusedWithExternalClaudeTarget() {
        let client = KeychainClient(snapshotReader: { _, _, _ in throw KeychainAccessError(status: -25293) },
                                    writer: { _, _ in })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnVaultTarget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = KeychainVault(root: root, client: client)
        #expect(vault.status() == .authorizationRequired(
            KeychainAuthorizationError(target: .subscriptionVault, status: -25293)))
    }

    @Test func ownVaultAuthorizationIsReadOnlyEvenWhenMigrationStateCouldExist() throws {
        struct Record: Codable { let version: Int; let entries: [String: Data] }
        let data = try JSONEncoder().encode(Record(version: 1, entries: ["account:fixture": Data([1])]))
        let reference = Data("vault-persistent".utf8)
        let recorder = Recorder()
        let client = KeychainClient(snapshotReader: { selector, _, _ in
            KeychainItemSnapshot(selector: selector, persistentReference: reference, data: data)
        }, writer: { [recorder] _, _ in recorder.recordWrite() })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnVaultReadOnly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try KeychainVault(root: root, client: client).authorize())
        #expect(recorder.writeCount == 0)
    }
}
