import Foundation
import SubscriptionCore

@MainActor
final class CodexLoginSession {
    private final class Attempt {
        let id = UUID()
        let continuation: AsyncThrowingStream<CodexLoginEvent, Error>.Continuation
        var task: Task<Void, Never>?
        var timers: [Task<Void, Never>] = []
        var process: CodexLoginProcess?
        var staging: CodexLoginStaging?
        var cancelMessage: JSONValue?
        var cancelled = false
        var failure: CodexLoginError?
        init(_ continuation: AsyncThrowingStream<CodexLoginEvent, Error>.Continuation) { self.continuation = continuation }
    }

    private var active: Attempt?
    var isIdle: Bool { active == nil }
    private let testExecutable: URL?
    private let stagingBase: URL
    private let timeout: Duration
    private let startupTimeout: Duration

    init(testExecutable: URL? = nil, stagingBase: URL? = nil,
         timeout: Duration = .seconds(600), startupTimeout: Duration = .seconds(20)) {
        self.testExecutable = testExecutable
        self.stagingBase = stagingBase ?? FileManager.default.temporaryDirectory
        self.timeout = timeout
        self.startupTimeout = startupTimeout
    }

    func start(method: CodexLoginMethod, workspaceID: String, applicationPath: String?) -> AsyncThrowingStream<CodexLoginEvent, Error> {
        let channel = AsyncThrowingStream<CodexLoginEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(2))
        guard active == nil else { channel.continuation.finish(throwing: CodexLoginError.alreadyRunning); return channel.stream }
        let attempt = Attempt(channel.continuation)
        active = attempt
        let attemptID = attempt.id
        channel.continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { Task { @MainActor in await self?.cancel(id: attemptID) } }
        }
        attempt.task = Task { [weak self] in await self?.run(attempt, method: method, workspaceID: workspaceID, applicationPath: applicationPath) }
        for (duration, startupOnly) in [(timeout, false), (startupTimeout, true)] {
            attempt.timers.append(Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                guard let self, self.active?.id == attempt.id, !startupOnly || attempt.cancelMessage == nil else { return }
                attempt.failure = .timeout
                attempt.task?.cancel()
            })
        }
        return channel.stream
    }

    func cancel() async { if let id = active?.id { await cancel(id: id) } }

    private func cancel(id: UUID) async {
        guard let attempt = active, attempt.id == id else { return }
        attempt.cancelled = true // Set before any suspension or cancellation RPC.
        if let message = attempt.cancelMessage { try? attempt.process?.send(message) }
        attempt.task?.cancel()
        await attempt.task?.value
        // A previous stop error retains ownership, so Cancel can retry cleanup.
        if active?.id == id {
            do { try await clean(attempt); finish(attempt, error: CancellationError()) }
            catch { attempt.continuation.finish(throwing: CodexLoginError.stopFailed) }
        }
    }

    private func check(_ attempt: Attempt) throws {
        if let failure = attempt.failure { throw failure }
        if attempt.cancelled || Task.isCancelled { throw CancellationError() }
        guard active?.id == attempt.id else { throw CancellationError() }
    }

    private func run(_ attempt: Attempt, method: CodexLoginMethod, workspaceID: String, applicationPath: String?) async {
        do {
            try check(attempt)
            guard CodexLoginProtocol.validText(workspaceID, maximum: 512) else { throw CodexLoginError.invalidWorkspace }
            let executable = try testExecutable ?? CodexLoginExecutable.resolve(applicationPath: applicationPath)
            let staging = try CodexLoginStaging(base: stagingBase)
            attempt.staging = staging
            let child = try CodexLoginProcess(executable: executable, arguments: CodexLoginStaging.arguments(workspaceID: workspaceID),
                                             environment: staging.environment, directory: staging.directory)
            attempt.process = child
            var protocolState = CodexLoginProtocol(method: method, workspaceID: workspaceID, cwd: staging.directory.path)
            var framer = CodexLoginFramer(maximumFrameBytes: 65_536)
            var stdoutBytes = 0, stderrBytes = 0
            try child.send(protocolState.initialize)
            for try await output in child.output {
                try check(attempt)
                switch output {
                case .stderr(let count):
                    stderrBytes += count
                    guard stderrBytes <= 131_072 else { throw CodexLoginError.oversizedOutput }
                case .exited: throw CodexLoginError.exited
                case .stdout(let bytes):
                    stdoutBytes += bytes.count
                    guard stdoutBytes <= 1_048_576 else { throw CodexLoginError.oversizedOutput }
                    for frame in try framer.append(bytes) {
                        for action in try protocolState.receive(frame) {
                            try check(attempt)
                            switch action {
                            case .send(let message): try child.send(message)
                            case .instructions(let instructions):
                                attempt.cancelMessage = protocolState.cancellation
                                if case .terminated = attempt.continuation.yield(.instructions(instructions)) { throw CancellationError() }
                            case .authenticated:
                                try await child.stop()
                                try check(attempt)
                                let credential = try staging.credential()
                                try staging.remove()
                                attempt.staging = nil
                                try check(attempt)
                                attempt.continuation.yield(.authenticated(credential))
                                finish(attempt, error: nil)
                                return
                            }
                        }
                    }
                }
            }
            try check(attempt)
            throw CodexLoginError.exited
        } catch {
            let failure: any Error
            if let reason = attempt.failure { failure = reason }
            else if attempt.cancelled || Task.isCancelled { failure = CancellationError() }
            else { failure = error as? CodexLoginError ?? .protocolFailure }
            do { try await clean(attempt); finish(attempt, error: failure) }
            catch {
                attempt.timers.forEach { $0.cancel() }
                attempt.continuation.finish(throwing: error as? CodexLoginError ?? .storage)
            }
        }
    }

    private func clean(_ attempt: Attempt) async throws {
        try await attempt.process?.stop()
        if let staging = attempt.staging { try staging.remove(); attempt.staging = nil }
    }

    private func finish(_ attempt: Attempt, error: (any Error)?) {
        attempt.timers.forEach { $0.cancel() }
        if active?.id == attempt.id { active = nil }
        if let error { attempt.continuation.finish(throwing: error) }
        else { attempt.continuation.finish() }
    }
}
