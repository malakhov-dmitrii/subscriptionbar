import Foundation
import SubscriptionCore

enum OpenCodeRepairCommand {
    static func run() async {
        do {
            let store = LocalStore(), vault = KeychainVault()
            let originalSettings = try SecureFiles.read(store.settingsURL)
            var settings = try store.loadSettings()
            guard let active = settings.active[.openCodeGo],
                  let index = settings.accounts.firstIndex(where: { $0.id == active && $0.provider == .openCodeGo }) else {
                throw AppFailure.missingCredential
            }
            let env = ProcessInfo.processInfo.environment
            let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
            let authURL = base.appendingPathComponent("opencode/auth.json")
            let override = env["OPENCODE_AUTH_CONTENT"].map { Data($0.utf8) }
            guard let originalAuth = try override ?? SecureFiles.read(authURL) else { throw AppFailure.missingCredential }
            let credential = try OpenCodeKeyImport.credential(originalAuth)
            guard let key = String(data: credential.primary, encoding: .utf8) else { throw AppFailure.invalidCredential }
            // Verify the subscription before changing the saved key.
            let reading = try await UsageAPI().fetch(UsageCredential(provider: .openCodeGo, bearer: key))
            let unchangedAuth = override != nil ? true : try SecureFiles.read(authURL) == originalAuth
            guard reading.isFresh(at: Date()), try SecureFiles.read(store.settingsURL) == originalSettings,
                  unchangedAuth else { throw AppFailure.concurrentChange }
            let previous = try store.loadCredential(active, vault: vault)
            try store.saveCredential(active, credential: credential, vault: vault)
            settings.accounts[index].identity = credential.identity
            do { _ = try store.saveSettings(settings, expected: originalSettings) }
            catch {
                try store.saveCredential(active, credential: previous, vault: vault)
                throw error
            }
            print("OPENCODE_REPAIRED: " + reading.windows.map { "\($0.name): \($0.remaining)% remaining" }.joined(separator: ", "))
        } catch {
            print("OPENCODE_REPAIR_FAILED: \(error.localizedDescription)")
        }
    }
}
