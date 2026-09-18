import Foundation
import SubscriptionCore

enum NativeHost {
    private static let manifests = ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Mozilla"]
    /// The settings screen states whether the installer has run, instead of
    /// leaving a five-step checklist with no feedback.
    static var isInstalled: Bool {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return manifests.contains { browser in
            FileManager.default.fileExists(atPath: support.appendingPathComponent(browser)
                .appendingPathComponent("NativeMessagingHosts/com.local.subscriptionbar.json").path)
        }
    }
    static func run() {
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        let bridge = BrowserBridge()
        while true {
            do {
                guard let header = try readExactly(4, input: input) else { return }
                let length = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                guard length > 0, length <= 1_048_576, let body = try readExactly(length, input: input) else { return }
                let request = try JSONValue.parse(body)
                guard let requestID = request["requestID"]?.string, UUID(uuidString: requestID) != nil else { return }
                var response: [String: JSONValue]
                do { response = try bridge.handle(request).object ?? ["ok": .bool(false)] }
                catch { response = ["ok": .bool(false), "error": .string("Operation failed. Check SubscriptionBar and sign-in.")] }
                response["requestID"] = .string(requestID)
                let data = try JSONValue.object(response).data()
                guard data.count <= 1_048_576 else { return }
                let count = UInt32(data.count).littleEndian
                try withUnsafeBytes(of: count) { try output.write(contentsOf: Data($0)) }
                try output.write(contentsOf: data)
            } catch { return }
        }
    }
    private static func readExactly(_ count: Int, input: FileHandle) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }
}
