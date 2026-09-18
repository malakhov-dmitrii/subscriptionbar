import Foundation

public struct LocalStore: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SubscriptionBar")
    }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    public func loadSettings() throws -> Settings {
        guard let data = try SecureFiles.read(settingsURL) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: data)
    }
    public func saveSettings(_ settings: Settings, expected: Data?) throws -> Data {
        let data = try JSONEncoder().encode(settings)
        try SecureFiles.write(data, to: settingsURL, expected: expected)
        return data
    }
    public func vaultKey(_ id: UUID) -> String { "account:\(id.uuidString)" }
    public func loadCredential(_ id: UUID, vault: any SecretStoring) throws -> CredentialEnvelope {
        guard let data = try vault.read(vaultKey(id)) else { throw AppFailure.missingCredential }
        return try JSONDecoder().decode(CredentialEnvelope.self, from: data)
    }
    public func saveCredential(_ id: UUID, credential: CredentialEnvelope, vault: any SecretStoring) throws {
        try vault.write(vaultKey(id), data: JSONEncoder().encode(credential))
    }
    public func saveReceipt(_ message: String) throws {
        let url = root.appendingPathComponent("last-result.json")
        let value = ["time": ISO8601DateFormatter().string(from: Date()), "message": message]
        try SecureFiles.write(JSONEncoder().encode(value), to: url, expected: SecureFiles.read(url))
    }
}

public struct BrowserCommand: Codable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let provider: Provider
    public let op: String
    public let createdAt: Date
    public init(account: Account) {
        id = UUID(); accountID = account.id; provider = account.provider; op = "activate"; createdAt = Date()
    }
}
public struct BrowserResult: Codable, Sendable {
    public let ok: Bool
    public let error: String?
}

public struct BrowserBridge: Sendable {
    public let store: LocalStore
    public let vault: any SecretStoring
    public init(store: LocalStore = LocalStore(), vault: any SecretStoring = KeychainVault()) {
        self.store = store; self.vault = vault
    }
    private var root: URL { store.root.appendingPathComponent("browsers") }
    public func folder(_ instance: UUID) -> URL { root.appendingPathComponent(instance.uuidString) }
    public func key(_ instance: UUID, _ account: UUID) -> String { "browser:\(instance.uuidString):\(account.uuidString)" }
    /// Any browser that reported in recently, regardless of saved accounts, so the
    /// settings screen can say whether the extension is talking to the app at all.
    public func connectedInstances() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let data = try SecureFiles.read(url.appendingPathComponent("seen.json")),
                  let date = try? JSONDecoder().decode(Date.self, from: data),
                  Date().timeIntervalSince(date) < 30 else { return nil }
            return id
        }
    }
    public func instances(for account: UUID, online: Bool = false) throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("capture-\(account.uuidString).json").path) else { return nil }
            if online {
                guard let data = try SecureFiles.read(url.appendingPathComponent("seen.json")),
                      let date = try? JSONDecoder().decode(Date.self, from: data), Date().timeIntervalSince(date) < 30 else { return nil }
            }
            return id
        }
    }
    public func cookies(account: UUID) throws -> [JSONValue]? {
        guard let instance = try instances(for: account).first,
              let data = try vault.read(key(instance, account)) else { return nil }
        return try JSONDecoder().decode([JSONValue].self, from: data)
    }
    public func requireReady(account: UUID) throws {
        let captured = try instances(for: account)
        let connected = try instances(for: account, online: true)
        guard !connected.isEmpty else { throw AppFailure.message("No connected browser has a saved session for the target account.") }
        guard Set(captured) == Set(connected) else { throw AppFailure.message("A browser with this account's saved session is offline. Open it before switching.") }
        guard let target = try store.loadSettings().accounts.first(where: { $0.id == account }) else { throw AppFailure.invalidCredential }
        for instance in captured {
            guard let data = try vault.read(key(instance, account)) else { throw AppFailure.missingCredential }
            try validate(cookies: JSONDecoder().decode([JSONValue].self, from: data), provider: target.provider)
        }
    }
    public func enqueue(account: Account) throws -> [(UUID, BrowserCommand)] {
        guard account.browserEnabled else { throw AppFailure.message("Browser switching is disabled for this account.") }
        try requireReady(account: account.id)
        let connected = try instances(for: account.id)
        return try connected.map { instance in
            let command = BrowserCommand(account: account)
            let url = folder(instance).appendingPathComponent("command-\(command.id.uuidString).json")
            try SecureFiles.write(JSONEncoder().encode(command), to: url, expected: nil)
            return (instance, command)
        }
    }
    public func awaitResults(_ commands: [(UUID, BrowserCommand)], timeout: Duration = .seconds(40)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: max(.zero, timeout))
        while clock.now < deadline {
            var complete = true
            for (instance, command) in commands {
                let url = folder(instance).appendingPathComponent("result-\(command.id.uuidString).json")
                guard let data = try SecureFiles.read(url) else { complete = false; continue }
                let result = try JSONDecoder().decode(BrowserResult.self, from: data)
                guard result.ok else {
                    try terminalizePending(commands)
                    throw AppFailure.message("Browser session could not be applied. Check its sign-in; automation is paused.")
                }
            }
            if complete { return }
            try await Task.sleep(for: min(.seconds(1), clock.now.duration(to: deadline)))
        }
        try terminalizePending(commands)
        throw AppFailure.message("Browser did not acknowledge the change. Its outcome is unknown; automation is paused.")
    }
    private func terminalizePending(_ commands: [(UUID, BrowserCommand)]) throws {
        // Prevent commands not yet loaded by the browser from starting after failure.
        // A browser that already loaded cookies may finish; its outcome stays unknown.
        for (instance, command) in commands {
            let url = folder(instance).appendingPathComponent("result-\(command.id.uuidString).json")
            if try SecureFiles.read(url) == nil {
                let terminal = BrowserResult(ok: false, error: "Browser transaction stopped; outcome unknown.")
                try writeFirstResult(terminal, to: url)
            }
        }
    }
    private func writeFirstResult(_ result: BrowserResult, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".result-\(UUID().uuidString)")
        try SecureFiles.write(JSONEncoder().encode(result), to: temporary, expected: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Hard-link publication is atomic and cannot replace a concurrent terminal receipt.
        do { try FileManager.default.linkItem(at: temporary, to: url) }
        catch { guard try SecureFiles.read(url) != nil else { throw error } }
    }
    public func handle(_ request: JSONValue) throws -> JSONValue {
        guard let instanceText = request["browserInstanceID"]?.string, let instance = UUID(uuidString: instanceText),
              let op = request["op"]?.string else { throw AppFailure.invalidCredential }
        let directory = folder(instance)
        let settings = try store.loadSettings()
        let accounts = settings.accounts.filter { $0.provider.hasCLIProfile }
        if op == "hello" {
            let seen = directory.appendingPathComponent("seen.json")
            try SecureFiles.write(JSONEncoder().encode(Date()), to: seen, expected: SecureFiles.read(seen))
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let commands: [JSONValue] = try files.filter { $0.lastPathComponent.hasPrefix("command-") }.compactMap { url in
                guard let data = try SecureFiles.read(url), let c = try? JSONDecoder().decode(BrowserCommand.self, from: data),
                      Date().timeIntervalSince(c.createdAt) < 45,
                      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("result-\(c.id.uuidString).json").path) else { return nil }
                return .object(["id": .string(c.id.uuidString), "accountID": .string(c.accountID.uuidString),
                                "provider": .string(c.provider.rawValue), "op": .string("activate")])
            }
            return .object(["ok": .bool(true), "accounts": .array(accounts.map {
                .object(["id": .string($0.id.uuidString), "label": .string($0.label), "provider": .string($0.provider.rawValue)])
            }), "pending": .array(commands)])
        }
        if op == "result" {
            guard let text = request["commandID"]?.string, let id = UUID(uuidString: text),
                  let ok = request["ok"]?.bool,
                  try SecureFiles.read(directory.appendingPathComponent("command-\(id.uuidString).json")) != nil else { throw AppFailure.invalidCredential }
            let url = directory.appendingPathComponent("result-\(id.uuidString).json")
            let result = BrowserResult(ok: ok, error: ok ? nil : "Browser session application failed.")
            if try SecureFiles.read(url) == nil { try writeFirstResult(result, to: url) }
            return .object(["ok": .bool(true)])
        }
        guard let accountText = request["accountID"]?.string, let accountID = UUID(uuidString: accountText),
              let account = accounts.first(where: { $0.id == accountID }),
              request["provider"]?.string == account.provider.rawValue else { throw AppFailure.invalidCredential }
        switch op {
        case "capture":
            guard let cookies = request["cookies"]?.array, !cookies.isEmpty, cookies.count < 500 else { throw AppFailure.invalidCredential }
            try validate(cookies: cookies, provider: account.provider)
            try vault.write(key(instance, accountID), data: JSONEncoder().encode(cookies))
            let marker = directory.appendingPathComponent("capture-\(accountID.uuidString).json")
            try SecureFiles.write(JSONEncoder().encode(Date()), to: marker, expected: SecureFiles.read(marker))
            return .object(["ok": .bool(true)])
        case "load":
            guard let text = request["commandID"]?.string, let commandID = UUID(uuidString: text),
                  try SecureFiles.read(directory.appendingPathComponent("result-\(commandID.uuidString).json")) == nil,
                  let raw = try SecureFiles.read(directory.appendingPathComponent("command-\(commandID.uuidString).json")),
                  let command = try? JSONDecoder().decode(BrowserCommand.self, from: raw),
                  command.accountID == accountID, command.provider == account.provider,
                  Date().timeIntervalSince(command.createdAt) < 45,
                  let data = try vault.read(key(instance, accountID)) else { throw AppFailure.missingCredential }
            let cookies = try JSONDecoder().decode([JSONValue].self, from: data)
            try validate(cookies: cookies, provider: account.provider)
            return .object(["ok": .bool(true), "cookies": .array(cookies)])
        default: throw AppFailure.unsupported("Unknown operation.")
        }
    }
    private func validate(cookies: [JSONValue], provider: Provider) throws {
        let hosts: [String]
        switch provider {
        case .claude: hosts = ["claude.ai"]
        case .codex: hosts = ["chatgpt.com", "auth.openai.com"]
        case .grok: hosts = ["grok.com", "auth.x.ai"]
        default: throw AppFailure.invalidCredential
        }
        guard !cookies.isEmpty, cookies.count <= 500 else { throw AppFailure.invalidCredential }
        var identities = Set<String>()
        var snapshotStore: String?
        for cookie in cookies {
            guard let domain = cookie["domain"]?.string,
                  let name = cookie["name"]?.string, !name.isEmpty,
                  let value = cookie["value"]?.string, value.utf8.count <= 65536,
                  !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else { throw AppFailure.invalidCredential }
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard hosts.contains(where: { host == $0 || (!$0.hasPrefix("auth.") && host.hasSuffix("." + $0)) }) else { throw AppFailure.invalidCredential }
            guard domain.range(of: "^\\.?[a-z0-9.-]+$", options: .regularExpression) != nil,
                  !name.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || ";,=".unicodeScalars.contains($0) }),
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  let path = cookie["path"]?.string, path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || "?#".unicodeScalars.contains($0) }),
                  let hostOnly = cookie["hostOnly"]?.bool,
                  cookie["secure"]?.bool != nil, cookie["httpOnly"]?.bool != nil,
                  let session = cookie["session"]?.bool,
                  let sameSite = cookie["sameSite"]?.string,
                  ["no_restriction", "lax", "strict", "unspecified"].contains(sameSite),
                  let cookieStore = cookie["storeId"]?.string,
                  ["0", "firefox-default"].contains(cookieStore),
                  cookie["partitionKey"] == nil || cookie["partitionKey"] == .null,
                  cookie["firstPartyDomain"] == nil || cookie["firstPartyDomain"] == .null || cookie["firstPartyDomain"] == .string(""),
                  !(hostOnly && domain.hasPrefix(".")) else { throw AppFailure.invalidCredential }
            if !session {
                guard case .number(let expiry) = cookie["expirationDate"], expiry.isFinite,
                      expiry > Date().timeIntervalSince1970 else { throw AppFailure.invalidCredential }
            }
            if let snapshotStore, snapshotStore != cookieStore { throw AppFailure.invalidCredential }
            snapshotStore = cookieStore
            guard identities.insert("\(domain)|\(path)|\(name)").inserted else { throw AppFailure.invalidCredential }
        }
    }
}
