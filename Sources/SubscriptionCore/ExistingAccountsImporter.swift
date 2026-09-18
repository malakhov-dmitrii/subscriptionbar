import Foundation
import Security

public struct ImportedAccount: Sendable {
    public var label: String
    public var provider: Provider
    public var credential: CredentialEnvelope
    public var isActive: Bool
    public var source: String
    public var monitoringOnly: Bool
}

public struct ImportReport: Sendable {
    public var accounts: [ImportedAccount] = []
    public var warnings: [String] = []
    public init() {}
}

/// Reads original stores without modifying or refreshing their credentials.
public struct ExistingAccountsImporter {
    public typealias Reader = (URL) throws -> Data?
    public typealias SecretReader = (String, String) throws -> Data?
    public typealias Capture = (Provider, Settings) throws -> CredentialEnvelope
    private let home: URL
    private let read: Reader
    private let secret: SecretReader
    private let capture: Capture

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                read: @escaping Reader = SecureFiles.read,
                readSecret: @escaping SecretReader = ExistingAccountsImporter.readTrackerSecret,
                capture: @escaping Capture = { try CLIConnector(settings: $1).capture($0) }) {
        self.home = home; self.read = read; self.secret = readSecret; self.capture = capture
    }

    public func discover(settings: Settings) throws -> [ImportedAccount] {
        discoverReport(settings: settings).accounts
    }

    public func discoverReport(settings: Settings) -> ImportReport {
        var report = ImportReport()
        var active: [Provider: CredentialEnvelope] = [:]
        for provider in [Provider.claude, .codex, .grok] {
            do {
                let credential = try capture(provider, settings)
                active[provider] = credential
                report.accounts.append(ImportedAccount(label: "\(provider.name) — current", provider: provider,
                    credential: credential, isActive: true, source: "Current \(provider.name) client", monitoringOnly: false))
            } catch {
                report.warnings.append("Current \(provider.name) credentials could not be imported. Check the original client's sign-in.")
            }
        }
        importCodex(active: active[.codex], report: &report)
        importClaude(active: active[.claude], report: &report)
        return report
    }

    private func importCodex(active: CredentialEnvelope?, report: inout ImportReport) {
        let folder = home.appendingPathComponent("Library/Application Support/Codex Account Switcher")
        do {
            guard let data = try read(folder.appendingPathComponent("accounts.json")) else { return }
            let registry = try JSONValue.parse(data)
            guard let profiles = registry["accounts"]?.array else { throw AppFailure.invalidCredential }
            for profile in profiles {
                do {
                    guard let text = profile["id"]?.string, let id = UUID(uuidString: text) else { throw AppFailure.invalidCredential }
                    let file = folder.appendingPathComponent("accounts").appendingPathComponent(id.uuidString).appendingPathComponent("auth.json")
                    guard let raw = try read(file) else { throw AppFailure.missingCredential }
                    let credential = try CredentialParser.parse(provider: .codex, data: raw)
                    let label = profile["displayName"]?.string ?? profile["email"]?.string ?? "Codex account"
                    merge(ImportedAccount(label: label, provider: .codex, credential: credential,
                        isActive: active?.identity == credential.identity, source: "Codex Account Switcher", monitoringOnly: false), into: &report)
                } catch {
                    report.warnings.append("A Codex Account Switcher profile could not be imported. Its original files were not changed.")
                }
            }
        } catch {
            report.warnings.append("Codex Account Switcher accounts.json could not be read.")
        }
    }

    private func importClaude(active: CredentialEnvelope?, report: inout ImportReport) {
        let file = home.appendingPathComponent("Library/Preferences/HamedElfayome.Claude-Usage.plist")
        do {
            guard let data = try read(file) else { return }
            guard let preferences = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let profilesData = preferences["profiles_v3"] as? Data,
                  let profiles = try JSONValue.parse(profilesData).array else { throw AppFailure.invalidCredential }
            for profile in profiles where profile["provider"]?.string == "anthropic" || profile["provider"] == nil {
                do {
                    guard let text = profile["id"]?.string, let id = UUID(uuidString: text) else { throw AppFailure.invalidCredential }
                    let prefix = id.uuidString + "."
                    let service = "com.claudeusagetracker.profile-credentials"
                    // Try both fields independently: an inaccessible CLI item must not hide a valid web session.
                    let session = readProfileSecret(service, prefix + "claude-session-key", fallback: profile["claudeSessionKey"]?.string)
                    var cli = readProfileSecret(service, prefix + "cli-credentials", fallback: profile["cliCredentialsJSON"]?.string)
                    if let pinned = profile["customKeychainServiceName"]?.string,
                       pinned == "Claude Code-credentials" || pinned.hasPrefix("Claude Code-credentials-") {
                        cli = readProfileSecret(pinned, NSUserName(), fallback: cli)
                    }
                    let org = profile["organizationId"]?.string
                    var metadata: JSONValue?
                    if let raw = profile["oauthAccountJSON"]?.string { metadata = try JSONValue.parse(Data(raw.utf8)) }
                    var credential: CredentialEnvelope?
                    if let cli {
                        credential = try? CredentialParser.parse(provider: .claude, data: Data(cli.utf8), metadata: metadata)
                    }
                    // Reuse current credentials only when their saved metadata proves the same organization.
                    if credential == nil, let active, let org,
                       active.metadata?["organizationUuid"]?.string == org,
                       let profileMetadata = metadata, profileMetadata["accountUuid"] == active.metadata?["accountUuid"] {
                        credential = active
                    }
                    let webOnly = credential == nil
                    if credential == nil, let session, !session.isEmpty, let org, UUID(uuidString: org) != nil {
                        credential = CredentialEnvelope(primary: Data(), identity: "web-org:" + org, metadata: metadata)
                    }
                    guard var credential else { throw AppFailure.missingCredential }
                    if let session, !session.isEmpty, let org, UUID(uuidString: org) != nil {
                        credential.webSessionKey = session
                        credential.webOrganizationID = org
                    }
                    merge(ImportedAccount(label: profile["name"]?.string ?? "Claude account", provider: .claude,
                        credential: credential, isActive: !webOnly && active?.identity == credential.identity,
                        source: "Claude Usage Tracker", monitoringOnly: webOnly), into: &report)
                    if webOnly { report.warnings.append("A Claude Tracker profile was imported for web usage monitoring only; no verified CLI credential was available.") }
                } catch {
                    report.warnings.append("A Claude Usage Tracker profile could not be imported. Its Keychain item may be inaccessible to this app.")
                }
            }
        } catch {
            report.warnings.append("Claude Usage Tracker profiles_v3 preferences could not be read.")
        }
    }

    private func readProfileSecret(_ service: String, _ account: String, fallback: String?) -> String? {
        if let data = try? secret(service, account), let value = String(data: data, encoding: .utf8), !value.isEmpty { return value }
        return fallback
    }

    private func merge(_ item: ImportedAccount, into report: inout ImportReport) {
        if let index = report.accounts.firstIndex(where: { $0.provider == item.provider && $0.credential.identity == item.credential.identity }) {
            let existing = report.accounts[index]
            var merged = item
            // Prefer live current CLI tokens over a saved snapshot that may have rotated.
            if existing.isActive {
                merged.credential = existing.credential
                merged.credential.webSessionKey = item.credential.webSessionKey ?? existing.credential.webSessionKey
                merged.credential.webOrganizationID = item.credential.webOrganizationID ?? existing.credential.webOrganizationID
                merged.isActive = true
            }
            report.accounts[index] = merged
        } else { report.accounts.append(item) }
    }

    public static func readTrackerSecret(service: String, account: String) throws -> Data? {
        try KeychainVault.withInteractionPolicy {
        var failure: OSStatus?
        for protected in [true, false] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            if protected { query[kSecUseDataProtectionKeychain as String] = true }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data { return data }
            if status != errSecItemNotFound { failure = status }
        }
        if failure != nil { throw AppFailure.message("Original Tracker Keychain item is inaccessible.") }
        return nil
        }
    }
}
