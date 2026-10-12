import Foundation
import SubscriptionCore

struct CodexProcessIdentity: Equatable, Sendable {
    let pid: Int32
    let launchedAt: Date?
    let applicationPath: String?
    let home: String?
}

struct CodexRestartReceipt: Sendable {
    let applicationURL: URL?
    let home: String
    let instances: [CodexProcessIdentity]
    let bundleIdentifier: String
}

struct CodexHandoffFailure: LocalizedError {
    let receipt: CodexRestartReceipt
    let reason: String
    var errorDescription: String? { reason }
}

enum CodexInstancePlanner {
    static func canonical(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw AppFailure.message("Use an absolute Codex data folder and application path.")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func plan(home: String, applicationPath: String?, registeredPaths: [String],
                     processes: [CodexProcessIdentity], bundleIdentifier: String = "com.openai.codex") throws -> CodexRestartReceipt {
        let home = try canonical(home)
        let path: String?
        if let applicationPath { path = try canonical(applicationPath) }
        else {
            let choices = try Set(registeredPaths.map(canonical))
            guard choices.count <= 1 else {
                throw AppFailure.message("Several Codex applications are registered. Choose an explicit application path for this profile.")
            }
            path = choices.first
        }
        // Unknown homes cannot prove that another client does not share this login.
        guard processes.allSatisfy({ $0.home != nil && $0.applicationPath != nil && $0.launchedAt != nil }) else {
            throw AppFailure.message("A running Codex instance could not be identified safely. Quit it manually and try again.")
        }
        let sharing = processes.filter { $0.home == home }
        guard sharing.count <= 1, sharing.allSatisfy({ $0.applicationPath == path }) else {
            throw AppFailure.message("Another Codex application uses this data folder. Give each profile its own CODEX_HOME or quit the shared instance.")
        }
        return CodexRestartReceipt(applicationURL: path.map { URL(fileURLWithPath: $0) }, home: home,
                                   instances: sharing, bundleIdentifier: bundleIdentifier)
    }

    static func validate(_ receipt: CodexRestartReceipt, processes: [CodexProcessIdentity], closed: Bool) throws {
        let current = try plan(home: receipt.home, applicationPath: receipt.applicationURL?.path,
                               registeredPaths: [], processes: processes)
        guard current.instances.allSatisfy({ receipt.instances.contains($0) }),
              !closed || current.instances.isEmpty else {
            throw AppFailure.message("The selected Codex instance changed or restarted. No further account changes are safe; retry after closing it.")
        }
    }
}

/// The same close sequence is used with native processes and disposable test fixtures.
@MainActor
struct CodexInstanceCloser {
    var snapshot: () throws -> [CodexProcessIdentity]
    var terminate: (CodexProcessIdentity) throws -> Bool
    var wait: () async throws -> Void
    var attempts = 30

    func close(_ receipt: CodexRestartReceipt) async throws {
        do {
            for target in receipt.instances {
                try Task.checkCancellation()
                let current = try snapshot()
                try CodexInstancePlanner.validate(receipt, processes: current, closed: false)
                guard current.contains(target) else { continue }
                guard try terminate(target) else {
                    throw AppFailure.message("Codex declined to quit. Complete its quit dialog; no account was changed.")
                }
            }
            for _ in 0..<attempts {
                try Task.checkCancellation()
                let current = try snapshot()
                try CodexInstancePlanner.validate(receipt, processes: current, closed: false)
                if !current.contains(where: { receipt.instances.contains($0) }) { return }
                try await wait()
            }
            throw AppFailure.message("Codex did not quit in time. No account was changed. Quit the selected instance manually and retry.")
        } catch {
            throw CodexHandoffFailure(receipt: receipt, reason: error.localizedDescription)
        }
    }
}
