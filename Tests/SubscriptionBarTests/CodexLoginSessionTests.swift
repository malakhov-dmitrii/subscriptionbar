import Foundation
import Testing
import SubscriptionCore
@testable import SubscriptionBar

@MainActor
@Suite(.serialized)
struct CodexLoginSessionTests {
    struct Fixture {
        let root: URL
        let staging: URL
        let executable: URL
        let auth: Data

        init(transform: (String) -> String = { $0 }) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexLoginTests-\(UUID())")
            staging = root.appendingPathComponent("staging")
            executable = root.appendingPathComponent("fake-codex")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let claims: JSONValue = .object(["sub": .string("fixture-user"), "exp": .number(4_000_000_000),
                "https://api.openai.com/auth": .object(["chatgpt_account_id": .string("workspace")])])
            let token = "fixture." + (try claims.data()).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".signature"
            auth = try JSONValue.object(["tokens": .object(["access_token": .string(token), "id_token": .string(token),
                "account_id": .string("workspace")])]).data()
            var script = """
            #!/bin/sh
            umask 077
            IFS= read -r request || exit 1
            printf '%s\\n' '{"id":1,"result":{"userAgent":"fixture"}}'
            IFS= read -r initialized || exit 1
            IFS= read -r request || exit 1
            printf '%s\\n' '{"id":2,"result":{"config":{"cli_auth_credentials_store":"file","forced_login_method":"chatgpt","forced_chatgpt_workspace_id":"workspace"}}}'
            IFS= read -r request || exit 1
            printf '%s' '{}' > "$CODEX_HOME/auth.json"
            printf '%s\\n' '{"id":3,"result":{"type":"chatgpt","loginId":"fixture-login","authUrl":"https://auth.openai.com/oauth/authorize?fixture=1"}}'
            printf '%s\\n' '{"method":"account/login/completed","params":{"loginId":"fixture-login","success":true}}'
            while IFS= read -r request; do :; done
            printf '%s' '\(String(decoding: auth, as: UTF8.self))' > "$CODEX_HOME/auth.json"
            """
            script = transform(script)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func browserLoginEmitsInstructionsThenCandidateAfterOwnedChildStops() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = CodexLoginSession(testExecutable: f.executable, stagingBase: f.staging,
                                        timeout: .seconds(3), startupTimeout: .seconds(2))
        #expect(session.isIdle)
        var events: [CodexLoginEvent] = []
        let stream = session.start(method: .browser, workspaceID: "workspace", applicationPath: nil)
        #expect(!session.isIdle)
        for try await event in stream { events.append(event) }
        #expect(session.isIdle)
        #expect(events.count == 2)
        guard case .instructions(let instructions) = events.first else { Issue.record("Expected login instructions"); return }
        #expect(instructions.loginID == "fixture-login")
        #expect(instructions.url.host == "auth.openai.com")
        guard case .authenticated(let credential) = events.last else { Issue.record("Expected authenticated candidate"); return }
        #expect(credential.primary == f.auth)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func deviceCodeInstructionsAndEarlyCompletionAreCorrelated() async throws {
        let f = try Fixture { script in
            let start = "{\"id\":3,\"result\":{\"type\":\"chatgpt\",\"loginId\":\"fixture-login\",\"authUrl\":\"https://auth.openai.com/oauth/authorize?fixture=1\"}}"
            let device = "{\"id\":3,\"result\":{\"type\":\"chatgptDeviceCode\",\"loginId\":\"fixture-login\",\"verificationUrl\":\"https://auth.openai.com/codex/device\",\"userCode\":\"ABCD-EFGH\"}}"
            let complete = "{\"method\":\"account/login/completed\",\"params\":{\"loginId\":\"fixture-login\",\"success\":true}}"
            return script.replacingOccurrences(of: start, with: complete).replacingOccurrences(of: "printf '%s\\n' '\(complete)'\nwhile", with: "printf '%s\\n' '\(device)'\nwhile")
        }
        let events = try await collect(f, method: .deviceCode)
        defer { f.clean() }
        #expect(events.count == 2)
        guard case .instructions(let value) = events.first else { Issue.record("Missing device instructions"); return }
        #expect(value.userCode == "ABCD-EFGH")
        #expect(value.url.path == "/codex/device")
    }

    @Test func splitAndCoalescedFramesAreHandled() async throws {
        let f = try Fixture { script in
            script.replacingOccurrences(of: "printf '%s\\n' '{\"id\":1,\"result\":{\"userAgent\":\"fixture\"}}'", with:
                "printf '%s' '{\"id\":1,'\n/bin/sleep 0.02\nprintf '%s\\n' '\"result\":{\"userAgent\":\"fixture\"}}'")
        }
        defer { f.clean() }
        #expect(try await collect(f).count == 2)
    }

    @Test(arguments: ["configuration", "missing-storage", "wrong-workspace", "initialize", "start", "failed-login", "malformed", "foreign-id", "foreign-completion", "early-completion-overflow", "unsafe-url", "stdout-limit", "stderr-limit", "missing-auth", "exit"])
    func rejectedOrIncompleteProtocolNeverEmitsCredential(scenario: String) async throws {
        let f = try Fixture { script in
            switch scenario {
            case "configuration": return script.replacingOccurrences(of: "\"cli_auth_credentials_store\":\"file\"", with: "\"cli_auth_credentials_store\":\"keyring\"")
            case "missing-storage": return script.replacingOccurrences(of: "\"cli_auth_credentials_store\":\"file\",", with: "")
            case "wrong-workspace": return script.replacingOccurrences(of: "\"forced_chatgpt_workspace_id\":\"workspace\"", with: "\"forced_chatgpt_workspace_id\":\"foreign\"")
            case "initialize": return script.replacingOccurrences(of: "{\"id\":1,\"result\":{\"userAgent\":\"fixture\"}}", with: "{\"id\":1,\"error\":{\"code\":1,\"message\":\"do not expose fixture details\"}}")
            case "start": return script.replacingOccurrences(of: "\"id\":3,\"result\":", with: "\"id\":3,\"error\":")
            case "failed-login": return script.replacingOccurrences(of: "\"success\":true", with: "\"success\":false")
            case "malformed": return script.replacingOccurrences(of: "{\"id\":1,\"result\":{\"userAgent\":\"fixture\"}}", with: "not-json")
            case "foreign-id": return script.replacingOccurrences(of: "\"id\":1", with: "\"id\":999")
            case "foreign-completion": return script.replacingOccurrences(of: "\"params\":{\"loginId\":\"fixture-login\"", with: "\"params\":{\"loginId\":\"another-login\"")
            case "early-completion-overflow":
                let early = (1...5).map { "printf '%s\\n' '{\"method\":\"account/login/completed\",\"params\":{\"loginId\":\"early-\($0)\",\"success\":true}}'" }.joined(separator: "\n")
                return script.replacingOccurrences(of: "printf '%s\\n' '{\"id\":3", with: early + "\nprintf '%s\\n' '{\"id\":3")
            case "unsafe-url": return script.replacingOccurrences(of: "https://auth.openai.com/", with: "https://auth.openai.com.evil.invalid/")
            case "stdout-limit": return script.replacingOccurrences(of: "{\"id\":1,\"result\":{\"userAgent\":\"fixture\"}}", with: String(repeating: "x", count: 66_000))
            case "stderr-limit": return "#!/bin/sh\nprintf '%s' '\(String(repeating: "x", count: 140_000))' >&2\nwhile IFS= read -r request; do :; done\n"
            case "missing-auth": return script.components(separatedBy: "\n").dropLast().joined(separator: "\n")
            default: return "#!/bin/sh\nexit 1\n"
            }
        }
        defer { f.clean() }
        var accepted = false
        do {
            let session = CodexLoginSession(testExecutable: f.executable, stagingBase: f.staging, timeout: .milliseconds(700), startupTimeout: .milliseconds(500))
            for try await event in session.start(method: .browser, workspaceID: "workspace", applicationPath: nil) {
                if case .authenticated = event { accepted = true }
            }
            Issue.record("Expected a bounded login failure")
        } catch { #expect(error is CodexLoginError) }
        #expect(!accepted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test(arguments: [false, true]) func cancelBeforeOrAfterInstructionsDiscardsRacedSuccess(afterInstructions: Bool) async throws {
        let f = try Fixture { script in
            if afterInstructions {
                return script.replacingOccurrences(of: "printf '%s\\n' '{\"method\":\"account/login/completed\"", with:
                    "IFS= read -r cancelRequest\nprintf '%s\\n' '{\"method\":\"account/login/completed\"")
            }
            return script.replacingOccurrences(of: "printf '%s\\n' '{\"id\":3", with:
                "while IFS= read -r waiting; do :; done\nprintf '%s\\n' '{\"id\":3")
        }
        defer { f.clean() }
        let session = CodexLoginSession(testExecutable: f.executable, stagingBase: f.staging, timeout: .seconds(3), startupTimeout: .seconds(2))
        let stream = session.start(method: .browser, workspaceID: "workspace", applicationPath: nil)
        #expect(!session.isIdle)
        let consumer = Task { () throws -> [CodexLoginEvent] in
            var events: [CodexLoginEvent] = []
            for try await event in stream {
                events.append(event)
                if afterInstructions { await session.cancel() }
            }
            return events
        }
        if !afterInstructions { try await Task.sleep(for: .milliseconds(100)); await session.cancel() }
        do { _ = try await consumer.value; Issue.record("Cancellation should end with CancellationError") }
        catch { #expect(error is CancellationError) }
        #expect(session.isIdle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func symlinkedAuthIsRejectedAndExternalSentinelIsUntouched() async throws {
        let f = try Fixture { script in
            var lines = script.components(separatedBy: "\n")
            lines.removeLast()
            lines += ["printf '%s' 'sentinel' > \"$CODEX_HOME/../sentinel\"",
                      "/bin/rm \"$CODEX_HOME/auth.json\"", "/bin/ln -s ../sentinel \"$CODEX_HOME/auth.json\""]
            return lines.joined(separator: "\n")
        }
        defer { f.clean() }
        do { _ = try await collect(f); Issue.record("Symlinked auth must be rejected") }
        catch { #expect(error as? CodexLoginError == .invalidAuthFile) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path) == ["sentinel"])
        #expect(try String(contentsOf: f.staging.appendingPathComponent("sentinel"), encoding: .utf8) == "sentinel")
    }

    @Test func unavailableExecutableAndImmediateCancelLeaveNoStaging() async throws {
        let f = try Fixture(); defer { f.clean() }
        let missing = CodexLoginSession(testExecutable: f.root.appendingPathComponent("missing"), stagingBase: f.staging)
        do {
            for try await _ in missing.start(method: .browser, workspaceID: "workspace", applicationPath: nil) {}
            Issue.record("Missing executable must fail")
        } catch { #expect(error as? CodexLoginError == .unavailable) }
        let canceled = CodexLoginSession(testExecutable: f.executable, stagingBase: f.staging)
        let stream = canceled.start(method: .browser, workspaceID: "workspace", applicationPath: nil)
        await canceled.cancel()
        do { for try await _ in stream {}; Issue.record("Canceled session must fail") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func workspaceQuotingAndDeliberateEnvironmentReachOnlyPrivateDirectory() async throws {
        let workspace = "team/\"quoted\"\\backslash'"
        let expectedArgument = "forced_chatgpt_workspace_id=\"team/\\\"quoted\\\"\\\\backslash'\""
        #expect(try CodexLoginStaging.arguments(workspaceID: workspace).last == expectedArgument)
        let encodedWorkspace = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
        func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var guards = """
        [ "$PWD" -ef "$CODEX_HOME" ] || exit 51
        [ "$HOME" = "$CODEX_HOME" ] || exit 52
        [ "$CODEX_SQLITE_HOME" = "$CODEX_HOME" ] || exit 53
        [ "$5" = 'cli_auth_credentials_store="file"' ] || exit 54
        [ "$7" = 'forced_login_method="chatgpt"' ] || exit 55
        [ "$9" = \(shellQuote(expectedArgument)) ] || exit 56
        [ -z "${OPENAI_API_KEY+x}${CODEX_ACCESS_TOKEN+x}${OPENAI_BASE_URL+x}" ] || exit 57
        """
        for code in 51...57 {
            guards = guards.replacingOccurrences(of: "exit \(code)", with:
                "{ printf '%s' '\(code)' > \"$CODEX_HOME/../guard-failure\"; exit \(code); }")
        }
        let f = try Fixture { script in
            script.replacingOccurrences(of: "umask 077", with: "umask 077\n" + guards)
                .replacingOccurrences(of: "\"forced_chatgpt_workspace_id\":\"workspace\"", with:
                    "\"forced_chatgpt_workspace_id\":" + encodedWorkspace.replacingOccurrences(of: "'", with: "'\\''"))
        }
        defer { f.clean() }
        let session = CodexLoginSession(testExecutable: f.executable, stagingBase: f.staging,
                                       timeout: .seconds(3), startupTimeout: .seconds(2))
        var verifiedPermissions = false
        do {
            for try await event in session.start(method: .browser, workspaceID: workspace, applicationPath: nil) {
                if case .instructions = event {
                    let folder = try #require(FileManager.default.contentsOfDirectory(at: f.staging, includingPropertiesForKeys: nil).first)
                    let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
                    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
                    verifiedPermissions = true
                }
            }
        } catch {
            if let code = try? String(contentsOf: f.staging.appendingPathComponent("guard-failure"), encoding: .utf8) {
                Issue.record("Fixture environment guard failed: \(code)")
            }
            throw error
        }
        #expect(verifiedPermissions)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test(arguments: ["", "   ", "bad\nworkspace"]) func invalidWorkspaceFailsBeforeLaunching(workspace: String) async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = CodexLoginSession(testExecutable: f.root.appendingPathComponent("missing"), stagingBase: f.staging)
        do {
            for try await _ in session.start(method: .browser, workspaceID: workspace, applicationPath: nil) {}
            Issue.record("Invalid workspace must fail")
        } catch { #expect(error as? CodexLoginError == .invalidWorkspace) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    @Test func concurrentStartDoesNotReplaceExistingAttemptAndSessionCanRestartAfterCancel() async throws {
        let f = try Fixture { script in
            script.replacingOccurrences(of: "printf '%s\\n' '{\"id\":1", with:
                "while IFS= read -r waiting; do :; done\nprintf '%s\\n' '{\"id\":1")
        }
        defer { f.clean() }
        let session = CodexLoginSession(testExecutable: f.executable, stagingBase: f.staging)
        let first = session.start(method: .browser, workspaceID: "workspace", applicationPath: nil)
        do {
            for try await _ in session.start(method: .deviceCode, workspaceID: "workspace", applicationPath: nil) {}
            Issue.record("Concurrent attempt must fail")
        } catch { #expect(error as? CodexLoginError == .alreadyRunning) }
        await session.cancel()
        do { for try await _ in first {}; Issue.record("First attempt should cancel") }
        catch { #expect(error is CancellationError) }
        let second = session.start(method: .browser, workspaceID: "workspace", applicationPath: nil)
        await session.cancel()
        do { for try await _ in second {}; Issue.record("Second attempt should cancel") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.staging.path).isEmpty)
    }

    private func collect(_ fixture: Fixture, method: CodexLoginMethod = .browser) async throws -> [CodexLoginEvent] {
        let session = CodexLoginSession(testExecutable: fixture.executable, stagingBase: fixture.staging,
                                       timeout: .seconds(3), startupTimeout: .seconds(2))
        var events: [CodexLoginEvent] = []
        for try await event in session.start(method: method, workspaceID: "workspace", applicationPath: nil) { events.append(event) }
        return events
    }
}
