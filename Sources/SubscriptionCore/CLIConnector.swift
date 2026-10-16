import Foundation

public struct CLIConnector: Sendable {
    public let settings: Settings
    public let keychain: KeychainClient
    public init(settings: Settings, keychain: KeychainClient = .system) {
        self.settings = settings
        self.keychain = keychain
    }
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
            let selector = try claudeKeychainSelector()
            if let raw = try keychain.read(selector, target: .claudeCode(selector)) {
                return try CredentialParser.parse(provider: provider, data: raw, metadata: metadata,
                                                  keychainService: selector.service)
            }
            guard let raw = try SecureFiles.read(root.appendingPathComponent(".credentials.json")) else { throw AppFailure.missingCredential }
            return try CredentialParser.parse(provider: provider, data: raw, metadata: metadata)
        case .codex, .grok:
            if provider == .codex, let config = try SecureFiles.read(root.appendingPathComponent("config.toml")),
               let text = String(data: config, encoding: .utf8),
               text.split(separator: "\n").contains(where: {
                   let line = $0.trimmingCharacters(in: .whitespaces)
                   guard !line.hasPrefix("#") else { return false }
                   let assignment = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                   guard assignment.count == 2,
                         assignment[0].trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store" else { return false }
                   let value = assignment[1].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                       .trimmingCharacters(in: .whitespaces)
                   return value != "\"file\"" && value != "'file'"
               }) {
                throw AppFailure.unsupported("Codex uses non-file credential storage. File switching cannot be verified for this configuration.")
            }
            guard let raw = try SecureFiles.read(root.appendingPathComponent("auth.json")) else { throw AppFailure.missingCredential }
            return try CredentialParser.parse(provider: provider, data: raw)
        default: throw AppFailure.unsupported("Add an API key in the account form.")
        }
    }

    public func claudeKeychainSelector() throws -> KeychainItemSelector {
        let root = try home(.claude)
        let hashedService = "Claude Code-credentials-" + SecureFiles.digest(Data(root.path.utf8)).prefix(8)
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL
        let service = root == defaultRoot ? "Claude Code-credentials" : String(hashedService)
        return KeychainItemSelector(service: service, account: NSUserName())
    }

    /// The account Claude Code is signed into, read from its config file only:
    /// no Keychain access, so it works even while token reads are unavailable.
    public func signedInClaudeAccount() throws -> (id: String, email: String?)? {
        let config = try claudeConfig(try home(.claude))
        let account = try JSONValue.parse(config.data)["oauthAccount"]
        guard let id = account?["accountUuid"]?.string, !id.isEmpty else { return nil }
        return (id, account?["emailAddress"]?.string)
    }

    public func authorizeClaudeKeychain(_ selector: KeychainItemSelector) throws -> KeychainVerificationResult {
        guard selector == (try claudeKeychainSelector()) else { throw AppFailure.concurrentChange }
        return try keychain.authorizeAndVerify(selector) { data in
            try claudeCredentialIdentity(data, selector: selector)
        }
    }

    public func claudeCredentialIdentity(_ data: Data, selector: KeychainItemSelector) throws -> String {
        guard selector == (try claudeKeychainSelector()) else { throw AppFailure.concurrentChange }
        let config = try claudeConfig(try home(.claude))
        let metadata = try JSONValue.parse(config.data)["oauthAccount"]
        return try CredentialParser.parse(provider: .claude, data: data, metadata: metadata,
                                          keychainService: selector.service).identity
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
                let selector = KeychainItemSelector(service: service, account: NSUserName())
                let authorizationTarget = KeychainAuthorizationTarget.claudeCode(selector)
                changes.append(Mutation(name: "Claude Keychain", before: current.primary, after: target.primary,
                    read: { try keychain.read(selector, target: authorizationTarget) }, replace: { data, expected in
                        guard try keychain.read(selector, target: authorizationTarget) == expected else { throw AppFailure.concurrentChange }
                        guard let data else { throw AppFailure.message("Cannot remove the client's Keychain item.") }
                        try keychain.write(selector, data: data, target: authorizationTarget)
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
