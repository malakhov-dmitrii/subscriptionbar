import Foundation
import Darwin
import CryptoKit

public enum SecureFiles {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func read(_ url: URL) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw AppFailure.message("Cannot inspect \(url.lastPathComponent).")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw AppFailure.message("Refusing a credential path that is not a regular file.")
        }
        return try Data(contentsOf: url)
    }
    public static func write(_ data: Data, to url: URL, expected: Data?) throws {
        guard try read(url) == expected else { throw AppFailure.concurrentChange }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".subscriptionbar-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppFailure.message("Cannot create secure temporary file.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard try read(url) == expected else { throw AppFailure.concurrentChange }
        guard rename(temporary.path, url.path) == 0 else { throw AppFailure.message("Atomic replacement failed.") }
    }
    public static func remove(_ url: URL, expected: Data) throws {
        guard try read(url) == expected else { throw AppFailure.concurrentChange }
        try FileManager.default.removeItem(at: url)
    }
}

public protocol SecretStoring: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ key: String, data: Data) throws
    func remove(_ key: String) throws
}

public struct CredentialEnvelope: Codable, Equatable, Sendable {
    public var primary: Data
    public var identity: String
    public var metadata: JSONValue?
    public var keychainService: String?
    public var webSessionKey: String?
    public var webOrganizationID: String?
    public init(primary: Data, identity: String, metadata: JSONValue? = nil, keychainService: String? = nil) {
        self.primary = primary; self.identity = identity; self.metadata = metadata; self.keychainService = keychainService
    }
}

public enum CredentialParser {
    public static func jwt(_ token: String) -> JSONValue? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONValue.parse(data)
    }
    public static func parse(provider: Provider, data: Data, metadata: JSONValue? = nil,
                             keychainService: String? = nil) throws -> CredentialEnvelope {
        let identity: String
        if provider == .cursor {
            guard let token = String(data: data, encoding: .utf8),
                  let subject = jwt(token)?["sub"]?.string, !subject.isEmpty else { throw AppFailure.invalidCredential }
            _ = try CursorLocalAuth.cookieHeader(token)
            identity = subject
        } else if !provider.hasCLIProfile {
            guard let key = String(data: data, encoding: .utf8), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !key.contains("\n"), !key.contains("\r") else { throw AppFailure.invalidCredential }
            identity = SecureFiles.digest(data)
        } else {
            let json = try JSONValue.parse(data)
            switch provider {
            case .claude:
                guard let token = json["claudeAiOauth"]?["accessToken"]?.string, !token.isEmpty,
                      let id = metadata?["accountUuid"]?.string ?? jwt(token)?["sub"]?.string, !id.isEmpty else {
                    throw AppFailure.invalidCredential
                }
                if let subject = jwt(token)?["sub"]?.string, subject != id {
                    throw AppFailure.invalidCredential
                }
                identity = id
            case .codex:
                guard let tokens = json["tokens"], let token = tokens["access_token"]?.string, !token.isEmpty,
                      let claims = jwt(tokens["id_token"]?.string ?? token),
                      let sub = claims["sub"]?.string, !sub.isEmpty,
                      let account = tokens["account_id"]?.string ?? claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string,
                      !account.isEmpty else { throw AppFailure.invalidCredential }
                let accessClaims = jwt(token)
                for subject in [claims["sub"]?.string, accessClaims?["sub"]?.string].compactMap({ $0 }) {
                    guard subject == sub else { throw AppFailure.invalidCredential }
                }
                for claimedAccount in [claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string,
                                       accessClaims?["https://api.openai.com/auth"]?["chatgpt_account_id"]?.string].compactMap({ $0 }) {
                    guard claimedAccount == account else { throw AppFailure.invalidCredential }
                }
                identity = sub + ":" + account
            case .grok:
                guard let record = grokRecord(json), let token = record["key"]?.string,
                      let sub = jwt(token)?["sub"]?.string, !sub.isEmpty else { throw AppFailure.invalidCredential }
                identity = sub
            default: throw AppFailure.invalidCredential
            }
        }
        return CredentialEnvelope(primary: data, identity: identity, metadata: metadata, keychainService: keychainService)
    }
    public static func grokRecord(_ root: JSONValue) -> JSONValue? {
        let records = root.object?.values.filter { $0["key"]?.string?.isEmpty == false } ?? []
        // Choosing an arbitrary dictionary entry could switch a different identity.
        return records.count == 1 ? records.first : nil
    }
}
