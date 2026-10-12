import Darwin
import Foundation
import SubscriptionCore

struct CodexLoginStaging {
    let directory: URL
    private let device: dev_t
    private let inode: ino_t

    init(base: URL) throws {
        let base = base.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(base.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw CodexLoginError.storage
        }
        var template = Array(base.appendingPathComponent("subscriptionbar-codex-login.XXXXXX").path.utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }) else { throw CodexLoginError.storage }
        directory = URL(fileURLWithPath: path)
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw CodexLoginError.storage }
        device = info.st_dev
        inode = info.st_ino
    }

    var environment: [String: String] {
        ["HOME": directory.path, "CODEX_HOME": directory.path, "CODEX_SQLITE_HOME": directory.path,
         "TMPDIR": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    }

    static func arguments(workspaceID: String) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(decoding: try encoder.encode(workspaceID), as: UTF8.self)
        return ["app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\"",
                "-c", "forced_login_method=\"chatgpt\"", "-c", "forced_chatgpt_workspace_id=" + quoted]
    }

    func credential() throws -> CredentialEnvelope {
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CodexLoginError.invalidAuthFile }
        defer { close(root) }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0, rootInfo.st_dev == device, rootInfo.st_ino == inode,
              rootInfo.st_uid == getuid() else { throw CodexLoginError.invalidAuthFile }
        let fd = openat(root, "auth.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CodexLoginError.invalidAuthFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= 262_144 else { throw CodexLoginError.invalidAuthFile }
        do {
            guard let bytes = try handle.read(upToCount: 262_145), bytes.count <= 262_144 else { throw CodexLoginError.invalidAuthFile }
            return try CredentialParser.parse(provider: .codex, data: bytes)
        } catch { throw CodexLoginError.invalidAuthFile }
    }

    func remove() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_dev == device, info.st_ino == inode, info.st_uid == getuid() else { throw CodexLoginError.storage }
        do { try FileManager.default.removeItem(at: directory) }
        catch { throw CodexLoginError.storage }
    }
}
