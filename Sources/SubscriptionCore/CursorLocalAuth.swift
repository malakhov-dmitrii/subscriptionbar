import Foundation
import SQLite3

public enum CursorLocalAuth {
    public static func read(databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")) throws -> CredentialEnvelope {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw AppFailure.message("Sign in to Cursor on this Mac before connecting it.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw AppFailure.invalidCredential
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw AppFailure.message("Sign in to Cursor on this Mac before connecting it.")
        }
        let token = String(cString: value)
        _ = try cookieHeader(token)
        return try CredentialParser.parse(provider: .cursor, data: Data(token.utf8))
    }

    public static func cookieHeader(_ token: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-=")
        guard !token.isEmpty, token.unicodeScalars.allSatisfy(allowed.contains),
              let subject = CredentialParser.jwt(token)?["sub"]?.string,
              let id = subject.split(separator: "|").last, !id.isEmpty,
              id.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-").contains) else {
            throw AppFailure.invalidCredential
        }
        return "WorkosCursorSessionToken=\(id)%3A%3A\(token)"
    }
}
