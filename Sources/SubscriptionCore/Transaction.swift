import Foundation

public struct Mutation {
    public let name: String
    public let before: Data?
    public let after: Data
    public let read: () throws -> Data?
    public let replace: (Data?, Data?) throws -> Void
    public init(name: String, before: Data?, after: Data, read: @escaping () throws -> Data?,
                replace: @escaping (Data?, Data?) throws -> Void) {
        self.name = name; self.before = before; self.after = after; self.read = read; self.replace = replace
    }
    public static func file(_ url: URL, after: Data) throws -> Mutation {
        let before = try SecureFiles.read(url)
        return Mutation(name: url.lastPathComponent, before: before, after: after,
                        read: { try SecureFiles.read(url) }, replace: { value, expected in
            if let value { try SecureFiles.write(value, to: url, expected: expected) }
            else if let expected { try SecureFiles.remove(url, expected: expected) }
        })
    }
}

public enum CredentialTransaction {
    public static func perform(_ mutations: [Mutation], verify: () throws -> Void) throws {
        // Check all preconditions before touching any destination.
        for item in mutations {
            guard try item.read() == item.before else { throw AppFailure.concurrentChange }
        }
        var applied: [Mutation] = []
        do {
            for item in mutations {
                // Include an attempted mutation: a write may succeed and then report an error.
                applied.append(item)
                try item.replace(item.after, item.before)
                guard try item.read() == item.after else { throw AppFailure.message("Credential write could not be verified.") }
            }
            try verify()
        } catch {
            var restorationFailed = false
            for item in applied.reversed() {
                do {
                    let current = try item.read()
                    if current == item.before { continue }
                    guard current == item.after else { restorationFailed = true; continue }
                    try item.replace(item.before, item.after)
                    if try item.read() != item.before { restorationFailed = true }
                } catch { restorationFailed = true }
            }
            if restorationFailed {
                throw AppFailure.message("Switch failed; a client changed credentials or restoration failed. Automation is paused. Check the active login in the original client.")
            }
            throw error
        }
    }
}
