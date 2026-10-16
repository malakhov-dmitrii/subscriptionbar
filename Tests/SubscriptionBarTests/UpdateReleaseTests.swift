import CryptoKit
import Foundation
import Testing
@testable import SubscriptionCore
@testable import SubscriptionBar

struct UpdateReleaseTests {
    static func release(tag: String = "v0.5.0", draft: Bool = false, assets: [String] = [
        "SubscriptionBar-0.5.0-macos-arm64.zip", "SHA256SUMS"]) throws -> Data {
        try JSONValue.object([
            "tag_name": .string(tag), "draft": .bool(draft), "prerelease": .bool(false),
            "html_url": .string("https://github.com/malakhov-dmitrii/subscriptionbar/releases/tag/\(tag)"),
            "assets": .array(assets.map { .object(["name": .string($0),
                "browser_download_url": .string("https://github.com/x/releases/download/\(tag)/\($0)")]) })
        ]).data()
    }

    @Test func parsesTheArm64ZipAndChecksumsOfAPublishedRelease() throws {
        let release = try #require(try UpdateRelease.parse(Self.release()))
        #expect(release.version == "0.5.0")
        #expect(release.archiveURL.lastPathComponent == "SubscriptionBar-0.5.0-macos-arm64.zip")
        #expect(release.checksumsURL.lastPathComponent == "SHA256SUMS")
        #expect(try UpdateRelease.parse(Self.release(draft: true)) == nil)
        #expect(try UpdateRelease.parse(Self.release(assets: ["SubscriptionBar-0.5.0-macos-arm64.zip"])) == nil)
        #expect(try UpdateRelease.parse(Self.release(tag: "nightly")) == nil)
    }

    @Test func comparesVersionsNumerically() throws {
        let release = try #require(try UpdateRelease.parse(Self.release()))
        #expect(release.isNewer(than: "0.4.2"))
        #expect(!release.isNewer(than: "0.5.0"))
        #expect(!release.isNewer(than: "0.10.0"))
        #expect(UpdateRelease.compare("0.10.0", "0.9.9") == .orderedDescending)
        #expect(UpdateRelease.compare("1.0", "1.0.0") == .orderedSame)
    }

    @Test func checksumMustNameThisArchiveWithThisDigest() throws {
        let release = try #require(try UpdateRelease.parse(Self.release()))
        let archive = Data("zip bytes".utf8)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        #expect(release.checksumMatches(archive: archive, sums: Data("\(digest)  SubscriptionBar-0.5.0-macos-arm64.zip\n".utf8)))
        #expect(!release.checksumMatches(archive: Data("tampered".utf8), sums: Data("\(digest)  SubscriptionBar-0.5.0-macos-arm64.zip\n".utf8)))
        #expect(!release.checksumMatches(archive: archive, sums: Data("\(digest)  Other.zip\n".utf8)))
    }

    /// Runs codesign against the installed notarized app and an ad-hoc copy of it.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/SubscriptionBar.app")))
    func codeRequirementAcceptsOnlyTheDeveloperIDBuild() throws {
        func satisfies(_ app: String) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--verify", "--strict", "--deep", "-R=\(UpdateRelease.codeRequirement)", app]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus == 0
        }
        #expect(try satisfies("/Applications/SubscriptionBar.app"))
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("adhoc-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/Applications/SubscriptionBar.app"), to: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", copy.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        #expect(sign.terminationStatus == 0)
        #expect(try !satisfies(copy.path))
    }

    /// Downloads the live latest release and runs every install check; opt in with SUBSCRIPTIONBAR_NETWORK_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUBSCRIPTIONBAR_NETWORK_TESTS"] == "1"))
    func liveLatestReleasePassesEveryInstallCheck() async throws {
        let release = try #require(try await AppUpdater.latest())
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let app = try await AppUpdater.prepare(release, in: work)
        #expect(Bundle(url: app)?.bundleIdentifier == "com.local.subscriptionbar")
    }
}
