import Foundation
import XCTest
@testable import SubscriptionCore

final class BrowserBridgeTests: XCTestCase {
    final class MemoryVault: SecretStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var data: [String: Data] = [:]
        func read(_ key: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data[key] }
        func write(_ key: String, data value: Data) throws { lock.lock(); defer { lock.unlock() }; data[key] = value }
        func remove(_ key: String) throws { lock.lock(); defer { lock.unlock() }; data.removeValue(forKey: key) }
    }
    struct Fixture {
        let directory: URL
        let account: Account
        let instance = UUID()
        let bridge: BrowserBridge
        let vault: MemoryVault
        init(provider: Provider = .claude) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionBar-BrowserTests-\(UUID())")
            account = Account(provider: provider, label: "Test account", identity: "test-identity", browserEnabled: true)
            let store = LocalStore(root: directory)
            var settings = Settings(); settings.accounts = [account]
            _ = try store.saveSettings(settings, expected: nil)
            vault = MemoryVault(); bridge = BrowserBridge(store: store, vault: vault)
        }
        func request(_ op: String, extra: [String: JSONValue] = [:]) -> JSONValue {
            .object(["op": .string(op), "requestID": .string(UUID().uuidString), "browserInstanceID": .string(instance.uuidString), "accountID": .string(account.id.uuidString), "provider": .string(account.provider.rawValue)].merging(extra) { _, right in right })
        }
        func clean() { try? FileManager.default.removeItem(at: directory) }
    }
    func cookie(domain: String = ".claude.ai", changes: [String: JSONValue] = [:]) -> JSONValue {
        .object(["domain": .string(domain), "name": .string("sessionKey"), "value": .string("test-value"), "path": .string("/"), "storeId": .string("0"), "hostOnly": .bool(false), "httpOnly": .bool(true), "secure": .bool(true), "session": .bool(false), "sameSite": .string("lax"), "expirationDate": .number(Date().timeIntervalSince1970 + 3600)].merging(changes) { _, right in right })
    }
    func testCaptureLoadAndResultAreScopedToIssuedCommand() throws {
        let f = try Fixture(); defer { f.clean() }
        let cookies: JSONValue = .array([cookie()])
        XCTAssertEqual(try f.bridge.handle(f.request("capture", extra: ["cookies": cookies]))["ok"], .bool(true))
        XCTAssertNotNil(try f.vault.read(f.bridge.key(f.instance, f.account.id)))
        _ = try f.bridge.handle(f.request("hello"))
        XCTAssertThrowsError(try f.bridge.handle(f.request("load", extra: ["commandID": .string(UUID().uuidString)])))
        let commands = try f.bridge.enqueue(account: f.account)
        let command = try XCTUnwrap(commands.first?.1)
        let loaded = try f.bridge.handle(f.request("load", extra: ["commandID": .string(command.id.uuidString)]))
        XCTAssertEqual(loaded["cookies"], cookies)
        XCTAssertThrowsError(try f.bridge.handle(f.request("load", extra: ["commandID": .string(command.id.uuidString), "browserInstanceID": .string(UUID().uuidString)])))
        let result = f.request("result", extra: ["commandID": .string(command.id.uuidString), "ok": .bool(true)])
        XCTAssertEqual(try f.bridge.handle(result)["ok"], .bool(true))
        XCTAssertEqual(try f.bridge.handle(result)["ok"], .bool(true))
        XCTAssertThrowsError(try f.bridge.handle(f.request("load", extra: ["commandID": .string(command.id.uuidString)])))
        XCTAssertEqual(try f.bridge.handle(f.request("hello"))["pending"]?.array?.count, 0)
    }
    func testRejectsForeignAccountsProviderAndInvalidUUIDs() throws {
        let f = try Fixture(); defer { f.clean() }
        for changes: [String: JSONValue] in [["accountID": .string(UUID().uuidString)], ["provider": .string("grok")], ["provider": .string("unknown")], ["accountID": .string("../escape")], ["browserInstanceID": .string("../escape")]] {
            XCTAssertThrowsError(try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie()])].merging(changes) { _, r in r })))
        }
        XCTAssertThrowsError(try f.bridge.handle(f.request("result", extra: ["commandID": .string(UUID().uuidString), "ok": .bool(true)])))
        XCTAssertNil(try f.vault.read(f.bridge.key(f.instance, f.account.id)))
    }
    func testRejectsUnrelatedAndAuthSubdomains() throws {
        let f = try Fixture(provider: .codex); defer { f.clean() }
        for domain in ["evilchatgpt.com", ".openai.com", "evil.auth.openai.com", "claude.ai"] {
            XCTAssertThrowsError(try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie(domain: domain)])])), domain)
        }
    }
    func testRejectsExpiredPartitionedAndNondefaultStoreCookies() throws {
        let f = try Fixture(); defer { f.clean() }
        for changes: [String: JSONValue] in [["expirationDate": .number(1)], ["storeId": .string("1")], ["partitionKey": .object(["topLevelSite": .string("https://claude.ai")])], ["sameSite": .string("invalid")], ["path": .string("/?bad")]] {
            XCTAssertThrowsError(try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie(changes: changes)])])))
        }
    }
    func testExpiredCommandCannotLoadSession() throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie()])]))
        _ = try f.bridge.handle(f.request("hello"))
        let command = try XCTUnwrap(f.bridge.enqueue(account: f.account).first?.1)
        let url = f.bridge.folder(f.instance).appendingPathComponent("command-\(command.id.uuidString).json")
        let old = try XCTUnwrap(SecureFiles.read(url))
        var json = try XCTUnwrap(JSONValue.parse(old).object)
        json["createdAt"] = .number(Date().addingTimeInterval(-60).timeIntervalSinceReferenceDate)
        try SecureFiles.write(JSONValue.object(json).data(), to: url, expected: old)
        XCTAssertThrowsError(try f.bridge.handle(f.request("load", extra: ["commandID": .string(command.id.uuidString)])))
        XCTAssertEqual(try f.bridge.handle(f.request("hello"))["pending"]?.array?.count, 0)
    }
    func testTimeoutPreventsLateLoadAndSuccessCannotReplaceTerminalFailure() async throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie()])]))
        _ = try f.bridge.handle(f.request("hello"))
        let commands = try f.bridge.enqueue(account: f.account)
        let command = try XCTUnwrap(commands.first?.1)
        do { try await f.bridge.awaitResults(commands, timeout: .zero); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unknown")) }
        XCTAssertThrowsError(try f.bridge.handle(f.request("load", extra: ["commandID": .string(command.id.uuidString)])))
        _ = try f.bridge.handle(f.request("result", extra: ["commandID": .string(command.id.uuidString), "ok": .bool(true)]))
        let url = f.bridge.folder(f.instance).appendingPathComponent("result-\(command.id.uuidString).json")
        let receipt = try JSONDecoder().decode(BrowserResult.self, from: XCTUnwrap(SecureFiles.read(url)))
        XCTAssertFalse(receipt.ok)
        XCTAssertEqual(try f.bridge.handle(f.request("hello"))["pending"]?.array?.count, 0)
    }
    func testOfflineCapturedBrowserPreventsAnyEnqueue() throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie()])]))
        _ = try f.bridge.handle(f.request("hello"))
        let offline = UUID()
        _ = try f.bridge.handle(f.request("capture", extra: ["browserInstanceID": .string(offline.uuidString), "cookies": .array([cookie()])]))
        XCTAssertThrowsError(try f.bridge.enqueue(account: f.account))
        XCTAssertEqual(try f.bridge.handle(f.request("hello"))["pending"]?.array?.count, 0)
    }
    func testOneBrowserFailureStopsOtherPendingBrowserLoads() async throws {
        let f = try Fixture(); defer { f.clean() }
        let secondInstance = UUID()
        for instance in [f.instance, secondInstance] {
            _ = try f.bridge.handle(f.request("capture", extra: ["browserInstanceID": .string(instance.uuidString), "cookies": .array([cookie()])]))
            _ = try f.bridge.handle(f.request("hello", extra: ["browserInstanceID": .string(instance.uuidString)]))
        }
        let commands = try f.bridge.enqueue(account: f.account)
        XCTAssertEqual(commands.count, 2)
        let failed = try XCTUnwrap(commands.first)
        _ = try f.bridge.handle(f.request("result", extra: ["browserInstanceID": .string(failed.0.uuidString), "commandID": .string(failed.1.id.uuidString), "ok": .bool(false)]))
        do { try await f.bridge.awaitResults(commands); XCTFail("Expected browser failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("paused")) }
        for (instance, command) in commands {
            XCTAssertThrowsError(try f.bridge.handle(f.request("load", extra: ["browserInstanceID": .string(instance.uuidString), "commandID": .string(command.id.uuidString)])))
            XCTAssertEqual(try f.bridge.handle(f.request("hello", extra: ["browserInstanceID": .string(instance.uuidString)]))["pending"]?.array?.count, 0)
        }
    }
    func testReadinessRejectsExpiredStoredSnapshotBeforeEnqueue() throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie()])]))
        _ = try f.bridge.handle(f.request("hello"))
        try f.vault.write(f.bridge.key(f.instance, f.account.id), data: JSONValue.array([cookie(changes: ["expirationDate": .number(1)])]).data())
        XCTAssertThrowsError(try f.bridge.requireReady(account: f.account.id))
        XCTAssertThrowsError(try f.bridge.enqueue(account: f.account))
        XCTAssertEqual(try f.bridge.handle(f.request("hello"))["pending"]?.array?.count, 0)
    }
    func testFirefoxDefaultSnapshotRoundTripsAndPassesReadiness() throws {
        let f = try Fixture(); defer { f.clean() }
        let cookies = JSONValue.array([cookie(changes: ["storeId": .string("firefox-default"), "firstPartyDomain": .string("")])])
        _ = try f.bridge.handle(f.request("capture", extra: ["cookies": cookies]))
        _ = try f.bridge.handle(f.request("hello"))
        XCTAssertNoThrow(try f.bridge.requireReady(account: f.account.id))
        let command = try XCTUnwrap(f.bridge.enqueue(account: f.account).first?.1)
        XCTAssertEqual(try f.bridge.handle(f.request("load", extra: ["commandID": .string(command.id.uuidString)]))["cookies"], cookies)
    }
    func testRejectsMixedStoresPrivateContainersAndFirstPartyDomains() throws {
        let f = try Fixture(); defer { f.clean() }
        let mixed = [cookie(), cookie(changes: ["storeId": .string("firefox-default"), "name": .string("other")])]
        XCTAssertThrowsError(try f.bridge.handle(f.request("capture", extra: ["cookies": .array(mixed)])))
        for changes: [String: JSONValue] in [
            ["storeId": .string("firefox-private")],
            ["storeId": .string("firefox-container-1")],
            ["storeId": .string("firefox-default"), "firstPartyDomain": .string("claude.ai")],
            ["storeId": .string("firefox-default"), "firstPartyDomain": .number(1)]
        ] {
            XCTAssertThrowsError(try f.bridge.handle(f.request("capture", extra: ["cookies": .array([cookie(changes: changes)])])))
        }
        XCTAssertNil(try f.vault.read(f.bridge.key(f.instance, f.account.id)))
    }
}
