import Foundation
import Security

/// Claude Code rewrites its Keychain item through `/usr/bin/security` on every
/// token refresh, which resets the item's partition list to `apple-tool:`.
/// Any "Always Allow" granted to this app is lost a few hours later, so the
/// item is read and written through the same tool Claude Code uses: it is in
/// the item's ACL and partition and never prompts.
enum ClaudeKeychainCLI {
    static let tool = URL(fileURLWithPath: "/usr/bin/security")
    private static let itemNotFound: Int32 = 44

    static func handles(_ selector: KeychainItemSelector) -> Bool {
        !selector.useDataProtectionKeychain && selector.accessGroup == nil && isClaudeService(selector.service)
    }

    static func isClaudeService(_ service: String) -> Bool {
        service == "Claude Code-credentials" || service.hasPrefix("Claude Code-credentials-")
    }

    static func read(_ selector: KeychainItemSelector) throws -> KeychainItemSnapshot? {
        // Arguments carry only the item name; the secret comes back over a pipe.
        let result = try run(["find-generic-password", "-s", selector.service, "-a", selector.account, "-w"], input: nil)
        if result.status == itemNotFound { return nil }
        guard result.status == 0 else { throw KeychainAccessError(status: errSecInternalComponent) }
        var data = result.output
        if data.last == UInt8(ascii: "\n") { data.removeLast() }
        // The item has no stable persistent reference through this tool. Its
        // name is the identity; callers compare decoded contents instead.
        return KeychainItemSnapshot(selector: selector, persistentReference: Data(selector.service.utf8), data: data)
    }

    static func write(_ selector: KeychainItemSelector, data: Data) throws {
        // `-i` reads the command from stdin so the secret never appears in argv.
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -s \(quoted(selector.service)) -a \(quoted(selector.account)) -X \(hex)\n"
        let result = try run(["-i"], input: Data(command.utf8))
        guard result.status == 0 else { throw KeychainAccessError(status: errSecInternalComponent) }
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ arguments: [String], input: Data?) throws -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe(), stdin = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
