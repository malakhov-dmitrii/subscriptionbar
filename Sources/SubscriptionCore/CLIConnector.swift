import Foundation

public struct CLIConnector: Sendable {
    public let settings: Settings
    public init(settings: Settings) { self.settings = settings }
    public func home(_ provider: Provider) throws -> URL {
        let path: String
        switch provider {
        case .claude: path = settings.claudeHome
        case .codex: path = settings.codexHome
        case .grok: path = settings.grokHome
        default: throw AppFailure.unsupported("This provider is balance/quota monitoring only.")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded.count > 1 else { throw AppFailure.message("Set an absolute client configuration folder.") }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
    public func capture(_ provider: Provider) throws -> CredentialEnvelope {
        let root = try home(provider)
        switch provider {
        case .claude:
            let config = try claudeConfig(root)
            let metadata = try JSONValue.parse(config.data)["oauthAccount"]
            let hashedService = "Claude Code-credentials-" + SecureFiles.digest(Data(root.path.utf8)).prefix(8)
            let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL
            let service = root == defaultRoot ? "Claude Code-credentials" : String(hashedService)
            if let raw = try KeychainVault.read(service: service, account: NSUserName()) {
                return try CredentialParser.parse(provider: provider, data: raw, metadata: metadata, keychainService: service)
            }
            guard let raw = try SecureFiles.read(root.appendingPathComponent(".credentials.json")) else { throw AppFailure.missingCredential }
            return try CredentialParser.parse(provider: provider, data: raw, metadata: metadata)
        case .codex, .grok:
            if provider == .codex, let config = try SecureFiles.read(root.appendingPathComponent("config.toml")),
               let text = String(data: config, encoding: .utf8),
               text.split(separator: "\n").contains(where: {
                   let line = $0.trimmingCharacters(in: .whitespaces)
                   return !line.hasPrefix("#") && line.hasPrefix("cli_auth_credentials_store") && (line.contains("keyring") || line.contains("auto"))
               }) {
                throw AppFailure.unsupported("Codex uses keyring/auto credential storage. File switching cannot be verified for this configuration.")
            }
            guard let raw = try SecureFiles.read(root.appendingPathComponent("auth.json")) else { throw AppFailure.missingCredential }
            return try CredentialParser.parse(provider: provider, data: raw)
        default: throw AppFailure.unsupported("Add an API key in the account form.")
        }
    }
    private func claudeConfig(_ root: URL) throws -> (url: URL, data: Data) {
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let candidates = root == defaultHome
            ? [root.deletingLastPathComponent().appendingPathComponent(".claude.json"), root.appendingPathComponent(".claude.json")]
            : [root.appendingPathComponent(".claude.json")]
        for url in candidates { if let data = try SecureFiles.read(url) { return (url, data) } }
        throw AppFailure.message("Claude account metadata was not found. Sign in with Claude Code first.")
    }
    public func apply(_ target: CredentialEnvelope, provider: Provider, current: CredentialEnvelope) throws {
        guard try capture(provider) == current else { throw AppFailure.concurrentChange }
        let root = try home(provider)
        var changes: [Mutation] = []
        if provider == .claude {
            if let service = current.keychainService {
                changes.append(Mutation(name: "Claude Keychain", before: current.primary, after: target.primary,
                    read: { try KeychainVault.read(service: service, account: NSUserName()) }, replace: { data, expected in
                        guard try KeychainVault.read(service: service, account: NSUserName()) == expected else { throw AppFailure.concurrentChange }
                        guard let data else { throw AppFailure.message("Cannot remove the client's Keychain item.") }
                        try KeychainVault.write(service: service, account: NSUserName(), data: data)
                    }))
            }
            let credentialFile = try Mutation.file(root.appendingPathComponent(".credentials.json"), after: target.primary)
            if current.keychainService == nil {
                guard credentialFile.before == current.primary else { throw AppFailure.concurrentChange }
            }
            changes.append(credentialFile)
            let config = try claudeConfig(root)
            guard var value = try JSONValue.parse(config.data).object, let metadata = target.metadata else { throw AppFailure.invalidCredential }
            guard value["oauthAccount"] == current.metadata else { throw AppFailure.concurrentChange }
            value["oauthAccount"] = metadata
            let configMutation = try Mutation.file(config.url, after: JSONValue.object(value).data())
            guard configMutation.before == config.data else { throw AppFailure.concurrentChange }
            changes.append(configMutation)
        } else {
            let mutation = try Mutation.file(root.appendingPathComponent("auth.json"), after: target.primary)
            guard mutation.before == current.primary else { throw AppFailure.concurrentChange }
            changes.append(mutation)
        }
        try CredentialTransaction.perform(changes) {
            guard try capture(provider).identity == target.identity else { throw AppFailure.invalidCredential }
        }
    }
}
