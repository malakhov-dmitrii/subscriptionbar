import AppKit
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
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }
        let url = running.first?.bundleURL
        for app in running {
            guard app.terminate() || app.isTerminated else {
                throw AppFailure.message("Codex declined to quit. Complete its quit dialog; no account was changed.")
            }
        }
        for _ in 0..<30 {
            if running.allSatisfy(\.isTerminated) { return url }
            try await Task.sleep(for: .seconds(1))
        }
        throw AppFailure.message("Codex did not quit within 30 seconds. No account was changed.")
    }
    static func reopen(_ url: URL?) async throws {
        guard let url else { return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}
