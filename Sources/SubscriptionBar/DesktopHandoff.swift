import AppKit
import Darwin
import SubscriptionCore

@MainActor
enum DesktopHandoff {
    static func closeLegacyTrackers() async throws -> Int {
        let identifiers: Set<String> = ["HamedElfayome.Claude-Usage", "com.liuzhao.codex-account-switcher", "com.local.grokusage"]
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier.map(identifiers.contains) ?? false
        }
        for app in apps {
            guard app.terminate() || app.isTerminated else { throw AppFailure.message("One of the old trackers declined to quit.") }
        }
        for _ in 0..<10 {
            if apps.allSatisfy(\.isTerminated) { return apps.count }
            try await Task.sleep(for: .seconds(1))
        }
        throw AppFailure.message("Some old trackers are still running. No processes were forcibly stopped.")
    }
    static func closeCodex() async throws -> URL? {
        let receipt = try await closeCodex(profile: CodexClientProfile(name: "Codex", home: NSHomeDirectory() + "/.codex"))
        return receipt.instances.isEmpty ? nil : receipt.applicationURL
    }

    static func closeCodex(profile: CodexClientProfile, bundleIdentifier: String = "com.openai.codex") async throws -> CodexRestartReceipt {
        let receipt = try CodexInstancePlanner.plan(home: profile.home, applicationPath: profile.applicationPath,
            registeredPaths: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier).map(\.path),
            processes: codexSnapshot(bundleIdentifier: bundleIdentifier), bundleIdentifier: bundleIdentifier)
        if let url = receipt.applicationURL { try verifyCodexBundle(url, bundleIdentifier: bundleIdentifier) }
        try await CodexInstanceCloser(snapshot: { try codexSnapshot(bundleIdentifier: bundleIdentifier) }, terminate: { identity in
            // Re-resolve immediately before sending a quit request; a reused PID is never enough.
            guard let app = NSRunningApplication(processIdentifier: identity.pid),
                  try codexIdentity(app, bundleIdentifier: bundleIdentifier) == identity else { throw AppFailure.concurrentChange }
            return app.isTerminated || app.terminate()
        }, wait: { try await Task.sleep(for: .seconds(1)) }).close(receipt)
        do { try validateCodexClosed(receipt) }
        catch { throw CodexHandoffFailure(receipt: receipt, reason: error.localizedDescription) }
        return receipt
    }

    static func validateCodexClosed(_ receipt: CodexRestartReceipt) throws {
        try CodexInstancePlanner.validate(receipt, processes: codexSnapshot(bundleIdentifier: receipt.bundleIdentifier), closed: true)
    }

    static func reopen(_ receipt: CodexRestartReceipt) async throws {
        guard !receipt.instances.isEmpty, let url = receipt.applicationURL else { return }
        let current = try codexSnapshot(bundleIdentifier: receipt.bundleIdentifier)
        try CodexInstancePlanner.validate(receipt, processes: current, closed: false)
        // A quit refusal, delayed quit, or partial close must not create another instance.
        guard !current.contains(where: { receipt.instances.contains($0) }) else { return }
        try verifyCodexBundle(url, bundleIdentifier: receipt.bundleIdentifier)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.environment = ["CODEX_HOME": receipt.home]
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        let identity = try codexIdentity(app, bundleIdentifier: receipt.bundleIdentifier)
        guard identity.applicationPath == url.path, identity.home == receipt.home else {
            throw AppFailure.message("Codex reopened with an unverified data folder. Automatic switching is paused; check the selected profile.")
        }
    }

    private static func verifyCodexBundle(_ url: URL, bundleIdentifier: String) throws {
        guard Bundle(url: url)?.bundleIdentifier == bundleIdentifier else {
            throw AppFailure.message("The selected application is not a Codex bundle. Choose the correct .app path.")
        }
    }

    static func codexSnapshot(bundleIdentifier: String = "com.openai.codex") throws -> [CodexProcessIdentity] {
        try NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.bundleIdentifier == bundleIdentifier
        }.compactMap { app in
            do { return try codexIdentity(app, bundleIdentifier: bundleIdentifier) }
            catch {
                // NSWorkspace can briefly retain a process after its argv vanished.
                // Skip only a proved exit, never an unreadable living instance.
                if app.isTerminated { return nil }
                if Darwin.kill(app.processIdentifier, 0) == -1 && errno == ESRCH { return nil }
                throw error
            }
        }
    }

    private static func codexIdentity(_ app: NSRunningApplication, bundleIdentifier: String) throws -> CodexProcessIdentity {
        guard app.bundleIdentifier == bundleIdentifier, let url = app.bundleURL,
              let launchedAt = app.launchDate else {
            throw AppFailure.message("Cannot verify a running Codex instance. Quit it manually and retry.")
        }
        return CodexProcessIdentity(pid: app.processIdentifier, launchedAt: launchedAt,
            applicationPath: try CodexInstancePlanner.canonical(url.path),
            home: try CodexProcessEnvironment.home(pid: app.processIdentifier))
    }
    static func reopen(_ url: URL?) async throws {
        guard let url else { return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
