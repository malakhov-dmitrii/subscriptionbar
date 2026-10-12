import Foundation
import SubscriptionCore
import Testing
@testable import SubscriptionBar

struct CodexInstanceTests {
    @Test func homeOverrideCannotBeMistakenForDefaultCodexHome() throws {
        func args(_ fields: [String]) -> Data {
            var argc: Int32 = 1
            var data = withUnsafeBytes(of: &argc) { Data($0) }
            data.append(Data(("/fixture\0\0fixture\0" + fields.joined(separator: "\0") + "\0\0").utf8))
            return data
        }
        let defaultHome = "/Users/fixture-owner/.codex"
        for fields in [["HOME=/Users/another-owner"], ["HOME=relative"], ["HOME="],
                       ["HOME=/Users/fixture-owner", "HOME=/Users/fixture-owner"]] {
            #expect(throws: (any Error).self) { try CodexProcessEnvironment.home(in: args(fields), defaultHome: defaultHome) }
        }
        #expect(try CodexProcessEnvironment.home(in: args(["HOME=/Users/fixture-owner"]), defaultHome: defaultHome) == defaultHome)
        #expect(try CodexProcessEnvironment.home(in: args(["HOME=/Users/another-owner", "CODEX_HOME=/Users/Shared/explicit-codex"]), defaultHome: defaultHome) == "/Users/Shared/explicit-codex")
    }

    @Test func sameApplicationAndHomeWithMultipleProcessesIsAmbiguous() throws {
        let first = CodexProcessIdentity(pid: 1, launchedAt: Date(), applicationPath: "/Applications/Codex.app", home: "/tmp/a")
        let second = CodexProcessIdentity(pid: 2, launchedAt: Date(), applicationPath: first.applicationPath, home: first.home)
        #expect(throws: (any Error).self) {
            try CodexInstancePlanner.plan(home: "/tmp/a", applicationPath: first.applicationPath, registeredPaths: [], processes: [first, second])
        }
    }

    @Test func nativeProcessInspectionReadsFixtureHome() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.environment = ["CODEX_HOME": "/Users/Shared/subscriptionbar-codex-native-inspection", "UNRELATED": "fixture-value"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        do {
            let home = try CodexProcessEnvironment.home(pid: process.processIdentifier)
            #expect(home == "/Users/Shared/subscriptionbar-codex-native-inspection")
        } catch AppFailure.message(let reason) {
            // macOS can hide the environment of platform binaries. Refusal is safe;
            // treating an unreadable environment as the default profile is not.
            #expect(reason.contains("data folder"))
        }
    }

    @Test @MainActor func processChangesBetweenPreflightAndQuitAreNeverTerminated() async throws {
        let original = CodexProcessIdentity(pid: 1, launchedAt: Date(timeIntervalSince1970: 1), applicationPath: "/Applications/Codex.app", home: "/tmp/a")
        let replacement = CodexProcessIdentity(pid: 1, launchedAt: Date(timeIntervalSince1970: 2), applicationPath: original.applicationPath, home: original.home)
        let receipt = try CodexInstancePlanner.plan(home: "/tmp/a", applicationPath: original.applicationPath, registeredPaths: [], processes: [original])
        var quitCalls = 0
        do {
            try await CodexInstanceCloser(snapshot: { [replacement] }, terminate: { _ in quitCalls += 1; return true }, wait: {}).close(receipt)
            Issue.record("Changed process must fail")
        } catch let failure as CodexHandoffFailure { #expect(failure.receipt.instances == [original]) }
        #expect(quitCalls == 0)
    }

    @Test @MainActor func ambiguousReceiptAndCancelledWaitKeepRecoveryReceipt() async throws {
        let first = CodexProcessIdentity(pid: 1, launchedAt: Date(), applicationPath: "/Applications/Codex.app", home: "/tmp/a")
        let second = CodexProcessIdentity(pid: 2, launchedAt: Date(), applicationPath: first.applicationPath, home: first.home)
        // Exercise recovery of an older/injected multi-process receipt. The planner
        // now rejects creating these receipts because one profile cannot distinguish them.
        let receipt = CodexRestartReceipt(applicationURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            home: "/tmp/a", instances: [first, second], bundleIdentifier: "com.openai.codex")
        var current = [first, second]
        do {
            try await CodexInstanceCloser(snapshot: { current }, terminate: { identity in
                if identity == first { current.removeAll { $0 == first }; return true }
                return false
            }, wait: {}).close(receipt)
                Issue.record("Ambiguous receipt must fail")
        } catch let failure as CodexHandoffFailure { #expect(failure.receipt.instances == [first, second]) }
        #expect(current == [first, second])
        do {
            try await CodexInstanceCloser(snapshot: { [first] }, terminate: { _ in true }, wait: { throw CancellationError() }).close(receipt)
            Issue.record("Cancelled wait must fail")
        } catch let failure as CodexHandoffFailure { #expect(failure.receipt.home == "/tmp/a") }
    }

    @Test func processArgumentsReadOnlyHomeAndRejectMalformedOrRelativeValues() throws {
        func args(_ env: [String]) -> Data {
            var argc: Int32 = 2
            var data = withUnsafeBytes(of: &argc) { Data($0) }
            data.append(Data("/bin/fixture\0\0fixture\0--test\0".utf8))
            data.append(Data((env.joined(separator: "\0") + "\0\0").utf8))
            return data
        }
        #expect(try CodexProcessEnvironment.home(in: args(["OTHER=private", "CODEX_HOME=/tmp/profile"]), defaultHome: "/tmp/default") == "/tmp/profile")
        #expect(try CodexProcessEnvironment.home(in: args(["OTHER=private"]), defaultHome: "/tmp/default") == "/tmp/default")
        #expect(throws: (any Error).self) { try CodexProcessEnvironment.home(in: args(["CODEX_HOME=relative"]), defaultHome: "/tmp/default") }
        #expect(throws: (any Error).self) { try CodexProcessEnvironment.home(in: Data([0]), defaultHome: "/tmp/default") }
        var hiddenEnvironment = args([])
        hiddenEnvironment.removeLast(2)
        #expect(throws: (any Error).self) { try CodexProcessEnvironment.home(in: hiddenEnvironment, defaultHome: "/tmp/default") }
        #expect(throws: (any Error).self) { try CodexProcessEnvironment.home(in: args([]), defaultHome: "/tmp/default") }
        #expect(throws: (any Error).self) { try CodexProcessEnvironment.home(in: args(["not-an-environment-entry"]), defaultHome: "/tmp/default") }
        #expect(throws: (any Error).self) { try CodexProcessEnvironment.home(in: args(["CODEX_HOME=/tmp/a", "CODEX_HOME=/tmp/b"]), defaultHome: "/tmp/default") }
    }

    @Test func unknownAndSharedHomesAndUnresolvedApplicationsRefuse() throws {
        let shared = CodexProcessIdentity(pid: 1, launchedAt: Date(), applicationPath: "/Applications/Other.app", home: "/tmp/a")
        let unknown = CodexProcessIdentity(pid: 2, launchedAt: Date(), applicationPath: "/Applications/Codex.app", home: nil)
        for processes in [[shared], [unknown]] {
            #expect(throws: (any Error).self) {
                try CodexInstancePlanner.plan(home: "/tmp/a", applicationPath: "/Applications/Codex.app", registeredPaths: [], processes: processes)
            }
        }
        #expect(throws: (any Error).self) {
            try CodexInstancePlanner.plan(home: "/tmp/a", applicationPath: nil,
                registeredPaths: ["/Applications/Codex.app", "/Applications/codex2.app"], processes: [])
        }
    }

    @Test func reusedPIDAndNewSharedInstanceRefuse() throws {
        let original = CodexProcessIdentity(pid: 1, launchedAt: Date(timeIntervalSince1970: 1), applicationPath: "/Applications/Codex.app", home: "/tmp/a")
        let receipt = try CodexInstancePlanner.plan(home: "/tmp/a", applicationPath: original.applicationPath, registeredPaths: [], processes: [original])
        let reused = CodexProcessIdentity(pid: 1, launchedAt: Date(timeIntervalSince1970: 2), applicationPath: original.applicationPath, home: original.home)
        #expect(throws: (any Error).self) { try CodexInstancePlanner.validate(receipt, processes: [reused], closed: false) }
        #expect(throws: (any Error).self) { try CodexInstancePlanner.validate(receipt, processes: [original], closed: true) }
    }

    @Test @MainActor func closeTargetsOnlySelectedInstanceAndKeepsRecoveryOnRefusalAndTimeout() async throws {
        let selected = CodexProcessIdentity(pid: 1, launchedAt: Date(), applicationPath: "/Applications/codex2.app", home: "/tmp/a")
        let other = CodexProcessIdentity(pid: 2, launchedAt: Date(), applicationPath: selected.applicationPath, home: "/tmp/b")
        let receipt = try CodexInstancePlanner.plan(home: "/tmp/a", applicationPath: selected.applicationPath, registeredPaths: [], processes: [selected, other])
        var processes = [selected, other]
        var terminated: [Int32] = []
        try await CodexInstanceCloser(snapshot: { processes }, terminate: { process in
            terminated.append(process.pid); processes.removeAll { $0 == process }; return true
        }, wait: {}).close(receipt)
        #expect(terminated == [1])
        #expect(processes == [other])
        for accepts in [false, true] {
            do {
                try await CodexInstanceCloser(snapshot: { [selected, other] }, terminate: { _ in accepts }, wait: {}, attempts: 1).close(receipt)
                Issue.record("Refusal or timeout must fail")
            } catch let failure as CodexHandoffFailure { #expect(failure.receipt.instances == [selected]) }
        }
    }

    @Test func renamedCopyWithSameURLDifferentHomesSelectsOnlyMatchingInstance() throws {
        let first = CodexProcessIdentity(pid: 101, launchedAt: Date(timeIntervalSince1970: 1),
            applicationPath: "/Applications/codex2.app", home: "/tmp/codex-a")
        let other = CodexProcessIdentity(pid: 102, launchedAt: Date(timeIntervalSince1970: 2),
            applicationPath: "/Applications/codex2.app", home: "/tmp/codex-b")
        let receipt = try CodexInstancePlanner.plan(home: "/tmp/codex-a",
            applicationPath: "/Applications/codex2.app", registeredPaths: [], processes: [first, other])
        #expect(receipt.instances == [first])
        #expect(receipt.home == "/tmp/codex-a")
    }
}
