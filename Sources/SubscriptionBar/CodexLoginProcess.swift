import AppKit
import Darwin
import Foundation
import SubscriptionCore

@MainActor
enum CodexLoginExecutable {
    static func resolve(applicationPath: String?) throws -> URL {
        var applications: [URL] = []
        if let applicationPath, applicationPath.hasPrefix("/") { applications.append(URL(fileURLWithPath: applicationPath)) }
        for identifier in ["com.openai.codex", "com.openai.chat"] {
            applications += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
        }
        let candidates = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
        for application in applications {
            let root = application.standardizedFileURL.resolvingSymlinksInPath()
            guard root.pathExtension == "app", let bundle = Bundle(url: root),
                  ["com.openai.codex", "com.openai.chat"].contains(bundle.bundleIdentifier ?? "") else { continue }
            for suffix in candidates {
                let executable = root.appendingPathComponent(suffix).resolvingSymlinksInPath()
                guard executable.path.hasPrefix(root.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path),
                      let handle = try? FileHandle(forReadingFrom: executable) else { continue }
                defer { try? handle.close() }
                let magic = try? handle.read(upToCount: 4)
                // Mach-O / universal binaries only. Never execute a shell or Node wrapper.
                if let magic, [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]),
                               Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca]),
                               Data([0xca, 0xfe, 0xba, 0xbf])].contains(magic) { return executable }
            }
        }
        throw CodexLoginError.unavailable
    }
}

/// Owns exactly one child. Protocol bytes and stderr never enter a log or error message.
@MainActor
final class CodexLoginProcess {
    enum Output: Sendable { case stdout(Data), stderr(Int), exited }
    let output: AsyncThrowingStream<Output, Error>
    private let continuation: AsyncThrowingStream<Output, Error>.Continuation
    private let process = Process()
    private let input: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL) throws {
        let channel = AsyncThrowingStream<Output, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        output = channel.stream
        continuation = channel.continuation
        let inPipe = Pipe(), outPipe = Pipe(), errorPipe = Pipe()
        input = inPipe.fileHandleForWriting
        stdout = outPipe.fileHandleForReading
        stderr = errorPipe.fileHandleForReading
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { throw CodexLoginError.protocolFailure }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in
            if case .dropped = channel.continuation.yield(.exited) { channel.continuation.finish(throwing: CodexLoginError.oversizedOutput) }
        }
        do { try process.run() }
        catch { throw CodexLoginError.unavailable }
        try? inPipe.fileHandleForReading.close()
        try? outPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        Self.drain(stdout, stderr: false, into: channel.continuation)
        Self.drain(stderr, stderr: true, into: channel.continuation)
    }

    func send(_ message: SubscriptionCore.JSONValue) throws {
        guard process.isRunning else { throw CodexLoginError.exited }
        do {
            var bytes = try message.data()
            bytes.append(10)
            try input.write(contentsOf: bytes)
        } catch { throw CodexLoginError.protocolFailure }
    }

    func stop() async throws {
        try? input.close()
        await waitForExit()
        if process.isRunning { process.terminate(); await waitForExit() }
        if process.isRunning {
            // This PID belongs to this still-running Process, never a discovered app.
            guard Darwin.kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else { throw CodexLoginError.stopFailed }
            await waitForExit()
        }
        guard !process.isRunning else { throw CodexLoginError.stopFailed }
        continuation.finish()
        try? stdout.close()
        try? stderr.close()
    }

    private func waitForExit() async {
        for _ in 0..<20 {
            if !process.isRunning { return }
            await Self.pause()
        }
    }

    private nonisolated static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(25)) { continuation.resume() }
        }
    }

    private nonisolated static func drain(_ handle: FileHandle, stderr: Bool,
                                         into continuation: AsyncThrowingStream<Output, Error>.Continuation) {
        DispatchQueue.global(qos: .utility).async {
            do {
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw CodexLoginError.protocolFailure }
                    if count == 0 { return }
                    let result = continuation.yield(stderr ? .stderr(count) : .stdout(Data(buffer.prefix(count))))
                    switch result {
                    case .enqueued: break
                    case .dropped: continuation.finish(throwing: CodexLoginError.oversizedOutput); return
                    case .terminated: return
                    @unknown default: continuation.finish(throwing: CodexLoginError.protocolFailure); return
                    }
                }
            } catch { continuation.finish(throwing: CodexLoginError.protocolFailure) }
        }
    }
}
