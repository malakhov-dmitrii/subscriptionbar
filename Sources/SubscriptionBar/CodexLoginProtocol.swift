import Foundation
import SubscriptionCore

enum CodexLoginMethod: Sendable, Equatable {
    case browser, deviceCode
    var wireName: String { self == .browser ? "chatgpt" : "chatgptDeviceCode" }
}

struct CodexLoginInstructions: Sendable, Equatable {
    let loginID: String
    let url: URL
    let userCode: String?
}

enum CodexLoginEvent: Sendable, Equatable {
    case instructions(CodexLoginInstructions)
    /// An isolated credential candidate. The caller must still verify user, workspace and quota.
    case authenticated(CredentialEnvelope)
}

enum CodexLoginError: Error, LocalizedError, Equatable, Sendable {
    case alreadyRunning, unavailable, invalidWorkspace, configuration, protocolFailure
    case startRejected, failed, timeout, exited, oversizedOutput, unsafeURL, invalidAuthFile, stopFailed, storage

    var errorDescription: String? {
        let key: String
        switch self {
        case .alreadyRunning: key = "A Codex sign-in is already running. Cancel it before starting another."
        case .unavailable: key = "A bundled native Codex CLI could not be found. Install or update Codex and try again."
        case .invalidWorkspace: key = "The saved Codex workspace could not be verified."
        case .configuration: key = "Codex sign-in requires file-backed ChatGPT authentication for the selected workspace."
        case .protocolFailure: key = "The Codex sign-in helper returned an unsupported response. Update Codex and try again."
        case .startRejected: key = "Codex could not start sign-in. Retry, or choose the other sign-in method."
        case .failed: key = "Codex sign-in did not complete. Retry with the saved account and workspace."
        case .timeout: key = "Codex sign-in timed out. Start sign-in again."
        case .exited: key = "The Codex sign-in helper stopped before authentication finished. Try again."
        case .oversizedOutput: key = "The Codex sign-in helper exceeded its output limit. No account was changed."
        case .unsafeURL: key = "Codex returned an untrusted sign-in address. No browser was opened."
        case .invalidAuthFile: key = "The isolated Codex sign-in did not produce a valid credential file."
        case .stopFailed: key = "The Codex sign-in helper could not be stopped safely. No credentials were accepted."
        case .storage: key = "The private Codex sign-in folder could not be prepared or cleaned safely."
        }
        return L10n.tr(key, table: "UI")
    }
}

struct CodexLoginFramer {
    let maximumFrameBytes: Int
    private var pending = Data()
    init(maximumFrameBytes: Int) { self.maximumFrameBytes = maximumFrameBytes }

    mutating func append(_ bytes: Data) throws -> [Data] {
        guard bytes.count <= maximumFrameBytes else { throw CodexLoginError.oversizedOutput }
        pending.append(bytes)
        var frames: [Data] = []
        while let end = pending.firstIndex(of: 10) {
            guard end <= maximumFrameBytes else { throw CodexLoginError.oversizedOutput }
            let frame = pending.prefix(upTo: end)
            if !frame.isEmpty { frames.append(Data(frame)) }
            pending.removeSubrange(...end)
        }
        guard pending.count <= maximumFrameBytes else { throw CodexLoginError.oversizedOutput }
        return frames
    }
}

struct CodexLoginProtocol {
    enum Action { case send(JSONValue), instructions(CodexLoginInstructions), authenticated }
    private enum Phase { case initialize, configuration, start, waiting, finished }
    private var phase = Phase.initialize
    private var earlyCompletions: [String: Bool] = [:]
    private(set) var loginID: String?
    let method: CodexLoginMethod
    let workspaceID: String
    let cwd: String
    init(method: CodexLoginMethod, workspaceID: String, cwd: String) {
        self.method = method; self.workspaceID = workspaceID; self.cwd = cwd
    }

    static func request(_ id: Int, _ method: String, _ params: JSONValue) -> JSONValue {
        .object(["id": .number(Double(id)), "method": .string(method), "params": params])
    }

    var initialize: JSONValue {
        Self.request(1, "initialize", .object(["clientInfo": .object([
            "name": .string("subscriptionbar"), "title": .string("SubscriptionBar"), "version": .string("0.4.0")
        ])]))
    }

    var cancellation: JSONValue? {
        loginID.map { Self.request(4, "account/login/cancel", .object(["loginId": .string($0)])) }
    }

    mutating func receive(_ data: Data) throws -> [Action] {
        guard let message = try? JSONValue.parse(data), message.object != nil else { throw CodexLoginError.protocolFailure }
        if message["method"]?.string == "account/login/completed" { return try completion(message["params"]) }
        let expectedID: Double
        switch phase {
        case .initialize: expectedID = 1
        case .configuration: expectedID = 2
        case .start: expectedID = 3
        case .waiting, .finished: return []
        }
        guard message["id"]?.number == expectedID else { return [] }
        if let error = message["error"], error != .null {
            throw phase == .start ? CodexLoginError.startRejected : .protocolFailure
        }
        guard let result = message["result"], result.object != nil else { throw CodexLoginError.protocolFailure }
        switch phase {
        case .initialize:
            phase = .configuration
            return [.send(.object(["method": .string("initialized")])),
                    .send(Self.request(2, "config/read", .object(["includeLayers": .bool(false), "cwd": .string(cwd)])))]
        case .configuration:
            let config = result["config"]
            let workspace = config?["forced_chatgpt_workspace_id"]
            let matchesWorkspace = workspace?.string == workspaceID || workspace?.array == [.string(workspaceID)]
            guard config?["cli_auth_credentials_store"]?.string == "file",
                  config?["forced_login_method"]?.string == "chatgpt", matchesWorkspace else { throw CodexLoginError.configuration }
            phase = .start
            return [.send(Self.request(3, "account/login/start", .object(["type": .string(method.wireName)])))]
        case .start:
            guard result["type"]?.string == method.wireName,
                  let id = result["loginId"]?.string, Self.validText(id, maximum: 512),
                  let rawURL = result[method == .browser ? "authUrl" : "verificationUrl"]?.string else {
                throw CodexLoginError.protocolFailure
            }
            let url = try Self.trustedURL(rawURL)
            let code = method == .deviceCode ? result["userCode"]?.string : nil
            if method == .deviceCode && !Self.validText(code ?? "", maximum: 128) { throw CodexLoginError.protocolFailure }
            loginID = id
            phase = .waiting
            var actions: [Action] = [.instructions(CodexLoginInstructions(loginID: id, url: url, userCode: code))]
            if let succeeded = earlyCompletions[id] { actions += try finish(succeeded) }
            earlyCompletions.removeAll()
            return actions
        case .waiting, .finished: return []
        }
    }

    private mutating func completion(_ params: JSONValue?) throws -> [Action] {
        guard let id = params?["loginId"]?.string, Self.validText(id, maximum: 512) else { return [] }
        guard case .bool(let success) = params?["success"] else { throw CodexLoginError.protocolFailure }
        switch phase {
        case .start:
            if let existing = earlyCompletions[id], existing != success { throw CodexLoginError.protocolFailure }
            guard earlyCompletions[id] != nil || earlyCompletions.count < 4 else { throw CodexLoginError.oversizedOutput }
            earlyCompletions[id] = success
            return []
        case .waiting: return id == loginID ? try finish(success) : []
        case .initialize, .configuration, .finished: return []
        }
    }

    private mutating func finish(_ success: Bool) throws -> [Action] {
        guard success else { throw CodexLoginError.failed }
        phase = .finished
        return [.authenticated]
    }

    static func validText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximum
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func trustedURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 16_384, let url = URL(string: text), url.scheme == "https",
              ["auth.openai.com", "chatgpt.com"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw CodexLoginError.unsafeURL }
        return url
    }
}
