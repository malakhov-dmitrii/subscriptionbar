import CryptoKit
import Foundation

/// The newest published GitHub release, reduced to what the updater needs.
public struct UpdateRelease: Equatable, Sendable {
    public static let latestURL = URL(string: "https://api.github.com/repos/malakhov-dmitrii/subscriptionbar/releases/latest")!
    /// Developer ID team, bundle id and Apple anchor an update must carry to be installed.
    public static let codeRequirement =
        #"anchor apple generic and identifier "com.local.subscriptionbar" and certificate leaf[subject.OU] = "XA54T94RVB""#

    public let version: String
    public let archiveName: String
    public let archiveURL: URL
    public let checksumsURL: URL
    public let notesURL: URL?

    /// Nil when the release is a draft, a prerelease, or lacks the arm64 zip and its checksums.
    public static func parse(_ data: Data) throws -> UpdateRelease? {
        let json = try JSONValue.parse(data)
        guard json["draft"]?.bool != true, json["prerelease"]?.bool != true,
              let tag = json["tag_name"]?.string, tag.hasPrefix("v") else { return nil }
        let version = String(tag.dropFirst())
        let archiveName = "SubscriptionBar-\(version)-macos-arm64.zip"
        var assets: [String: URL] = [:]
        for asset in json["assets"]?.array ?? [] {
            if let name = asset["name"]?.string, let link = asset["browser_download_url"]?.string,
               let url = URL(string: link), url.scheme == "https" { assets[name] = url }
        }
        guard let archive = assets[archiveName], let sums = assets["SHA256SUMS"] else { return nil }
        return UpdateRelease(version: version, archiveName: archiveName, archiveURL: archive, checksumsURL: sums,
                             notesURL: json["html_url"]?.string.flatMap(URL.init(string:)))
    }

    public func isNewer(than current: String) -> Bool {
        Self.compare(version, current) == .orderedDescending
    }

    /// Numeric dotted comparison: "0.10.0" is newer than "0.9.9".
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }, b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True only when SHA256SUMS lists exactly this archive with this digest.
    public func checksumMatches(archive: Data, sums: Data) -> Bool {
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let lines = String(decoding: sums, as: UTF8.self).split(whereSeparator: \.isNewline)
        return lines.contains { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count == 2 && parts[0].lowercased() == digest
                && parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == archiveName
        }
    }
}
