import Foundation

public enum OpenCodeKeyImport {
    public static func credential(_ data: Data) throws -> CredentialEnvelope {
        let root = try JSONValue.parse(data)
        guard let record = root["opencode-go"], record["type"]?.string == "api",
              let key = record["key"]?.string, !key.isEmpty else { throw AppFailure.missingCredential }
        return try CredentialParser.parse(provider: .openCodeGo, data: Data(key.utf8))
    }
}
