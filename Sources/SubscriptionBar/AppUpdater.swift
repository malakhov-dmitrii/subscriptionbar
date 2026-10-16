import AppKit
import SubscriptionCore

/// Checks GitHub Releases once a day and installs an update on request.
/// An update is installed only after its zip matches SHA256SUMS, its code
/// signature satisfies `UpdateRelease.codeRequirement` (this Developer ID team
/// and bundle id), Gatekeeper accepts it as notarized, and its version matches.
enum AppUpdater {
    /// No cookies or cache. Redirects are allowed: release assets are served
    /// from GitHub's storage host, and the signature checks decide trust.
    private static let session = URLSession(configuration: .ephemeral)
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    /// Only a real app bundle can replace itself; `swift run` and tests cannot.
    static var installedBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    static func latest() async throws -> UpdateRelease? {
        var request = URLRequest(url: UpdateRelease.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SubscriptionBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try UpdateRelease.parse(data)
    }

    /// Downloads and verifies the update, swaps the bundle in place and relaunches.
    static func install(_ release: UpdateRelease) async throws {
        guard let bundle = installedBundle else { throw AppFailure.message(L10n.tr("Updates install only into an installed app.")) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SubscriptionBar-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try await prepare(release, in: work)
        // ponytail: replaceItemAt swaps atomically on one volume; the running
        // process keeps its mapped binary until it quits.
        _ = try FileManager.default.replaceItemAt(bundle, withItemAt: app)
        await relaunch(bundle)
    }

    /// Returns the unpacked app only after every check passes.
    static func prepare(_ release: UpdateRelease, in work: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (archive, _) = try await session.data(from: release.archiveURL)
        let (sums, _) = try await session.data(from: release.checksumsURL)
        guard release.checksumMatches(archive: archive, sums: sums) else { throw failure("checksum") }
        let zip = work.appendingPathComponent(release.archiveName)
        try archive.write(to: zip)
        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], "unzip")
        let app = unpacked.appendingPathComponent("SubscriptionBar.app")
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", "-R=\(UpdateRelease.codeRequirement)", app.path], "signature")
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], "notarization")
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version == release.version else { throw failure("version") }
        return app
    }

    @MainActor private static func relaunch(_ bundle: URL) {
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, bundle.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String], _ step: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure(step) }
    }

    private static func failure(_ step: String) -> AppFailure {
        .message(L10n.tr("The update failed its %@ check and was not installed.", step))
    }
}
