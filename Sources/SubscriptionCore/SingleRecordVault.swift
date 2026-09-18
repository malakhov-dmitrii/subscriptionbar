import Foundation
import Darwin

public enum VaultStatus: Equatable, Sendable { case ready, missing, locked, invalid }
public enum VaultDataError: Error, LocalizedError, Sendable {
    case invalidRecord, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalidRecord: L10n.tr("Saved vault data is invalid. Unlocking cannot repair its format.")
        case .unsupportedVersion: L10n.tr("Saved vault version is unsupported.")
        }
    }
}
public protocol RawVaultStoring: Sendable {
    func read(service: String, account: String, allowUserInteraction: Bool) throws -> Data?
    func write(service: String, account: String, data: Data, allowUserInteraction: Bool) throws
}

public struct SingleRecordVault: SecretStoring {
    public static let account = "vault-v1"
    public let service: String
    public let root: URL
    private let raw: any RawVaultStoring
    private let lockTimeout: TimeInterval
    private struct Record: Codable {
        let version: Int
        var entries: [String: Data]
        init(entries: [String: Data] = [:]) { version = 1; self.entries = entries }
    }
    public init(service: String, root: URL, raw: any RawVaultStoring, lockTimeout: TimeInterval = 0.2) {
        self.service = service; self.root = root; self.raw = raw
        self.lockTimeout = max(0, min(lockTimeout, 2))
    }
    public func read(_ key: String) throws -> Data? { try load(allowUserInteraction: false)?.entries[key] }
    public func write(_ key: String, data: Data) throws {
        try withLock {
            var record = try load(allowUserInteraction: false) ?? Record()
            record.entries[key] = data
            try save(record)
        }
    }
    public func remove(_ key: String) throws {
        try withLock {
            guard var record = try load(allowUserInteraction: false), record.entries.removeValue(forKey: key) != nil else { return }
            try save(record)
        }
    }
    /// Explicit foreground action: one consolidated read, outside flock, without retry.
    public func authorize() throws -> Bool { try load(allowUserInteraction: true) != nil }
    public func status() -> VaultStatus {
        do { return try load(allowUserInteraction: false) == nil ? .missing : .ready }
        catch is VaultDataError { return .invalid }
        catch { return .locked }
    }
    /// A single locked merge writes only vault-v1; it never reads or deletes legacy items.
    public func importEntries(_ entries: [String: Data]) throws {
        guard !entries.isEmpty else { return }
        try withLock {
            var record = try load(allowUserInteraction: false) ?? Record()
            for (key, incoming) in entries {
                if let existing = record.entries[key], existing != incoming { throw AppFailure.concurrentChange }
            }
            record.entries.merge(entries) { existing, _ in existing }
            try save(record)
        }
    }
    private func load(allowUserInteraction: Bool) throws -> Record? {
        guard let data = try raw.read(service: service, account: Self.account, allowUserInteraction: allowUserInteraction) else { return nil }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw VaultDataError.invalidRecord }
        guard record.version == 1 else { throw VaultDataError.unsupportedVersion }
        return record
    }
    private func save(_ record: Record) throws {
        try raw.write(service: service, account: Self.account, data: JSONEncoder().encode(record), allowUserInteraction: false)
    }
    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(root.path, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid() else { throw AppFailure.message("Vault lock directory is not a trusted directory.") }
        let descriptor = open(root.appendingPathComponent("vault-v1.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppFailure.message("Cannot open vault lock.") }
        defer { close(descriptor) }
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0, (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == getuid(), fileInfo.st_nlink == 1, fchmod(descriptor, 0o600) == 0 else {
            throw AppFailure.message("Vault lock file is not a trusted regular file.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + lockTimeout
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw AppFailure.message("Cannot acquire vault lock.") }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AppFailure.message("Vault is busy. Try again shortly.") }
            usleep(5_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
