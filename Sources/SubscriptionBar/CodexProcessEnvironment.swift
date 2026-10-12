import Darwin
import Foundation
import SubscriptionCore

/// Reads process arguments privately; only the verified credential-home path leaves this boundary.
enum CodexProcessEnvironment {
    static func home(pid: Int32) throws -> String {
        var limit = 0
        var limitSize = MemoryLayout<Int>.size
        var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&limitMIB, 2, &limit, &limitSize, nil, 0) == 0, limit > 0, limit <= 16_777_216 else {
            throw AppFailure.message("Cannot inspect the Codex instance data folder.")
        }
        var bytes = [UInt8](repeating: 0, count: limit)
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var size = limit
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { throw AppFailure.message("Cannot inspect the Codex instance data folder. Quit it manually and retry.") }
        return try home(in: Data(bytes.prefix(size)), defaultHome: NSHomeDirectory() + "/.codex")
    }

    static func home(in data: Data, defaultHome: String) throws -> String {
        guard data.count >= MemoryLayout<Int32>.size else { throw AppFailure.invalidCredential }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < data.count else { throw AppFailure.invalidCredential }
        var cursor = MemoryLayout<Int32>.size
        func next() throws -> Data.SubSequence {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0) else { throw AppFailure.invalidCredential }
            let value = data[cursor..<end]; cursor = end + 1
            return value
        }
        _ = try next() // Executable, then alignment padding, then argc argument strings.
        while cursor < data.count && data[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc { _ = try next() }
        guard cursor < data.count else {
            throw AppFailure.message("Cannot inspect the Codex instance data folder: macOS hid its environment. Quit it manually and retry.")
        }
        let prefix = Data("CODEX_HOME=".utf8)
        let homePrefix = Data("HOME=".utf8)
        var value: String?
        var processHome: String?
        var observedField = false
        var completeEnvironment = false
        while cursor < data.count {
            let field = try next()
            if field.isEmpty { completeEnvironment = true; break }
            guard let separator = field.firstIndex(of: 61), separator > field.startIndex else {
                throw AppFailure.message("Cannot inspect the Codex instance data folder. Quit it manually and retry.")
            }
            observedField = true
            if field.starts(with: prefix) {
                guard value == nil, let text = String(data: field.dropFirst(prefix.count), encoding: .utf8), text.hasPrefix("/") else {
                    throw AppFailure.message("Codex uses an ambiguous or relative CODEX_HOME. Configure an absolute data folder and restart it.")
                }
                value = text
            } else if field.starts(with: homePrefix) {
                guard processHome == nil, let text = String(data: field.dropFirst(homePrefix.count), encoding: .utf8), text.hasPrefix("/") else {
                    throw AppFailure.message("Cannot verify Codex HOME. Use a single absolute HOME value and an explicit absolute CODEX_HOME, then restart it.")
                }
                processHome = text
            }
        }
        guard observedField && completeEnvironment else {
            throw AppFailure.message("Cannot inspect the Codex instance data folder: macOS hid its environment. Quit it manually and retry.")
        }
        if value == nil, let processHome {
            let expectedHome = URL(fileURLWithPath: defaultHome).deletingLastPathComponent().path
            guard try CodexInstancePlanner.canonical(processHome) == CodexInstancePlanner.canonical(expectedHome) else {
                throw AppFailure.message("Codex uses a different HOME. Set an explicit absolute CODEX_HOME and restart it.")
            }
        }
        return try CodexInstancePlanner.canonical(value ?? defaultHome)
    }
}
