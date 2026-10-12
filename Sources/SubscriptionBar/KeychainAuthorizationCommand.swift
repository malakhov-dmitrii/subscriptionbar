import Darwin
import Foundation
import SubscriptionCore

private struct KeychainAuthorizationReceipt: Codable {
    let persistentReference: Data
    let identity: String
}

enum KeychainAuthorizationCommand {
    static let flag = "--keychain-authorization-helper"

    static var isHelper: Bool { CommandLine.arguments.contains(flag) }

    /// Runs in a short-lived process. No app services, polling, or writes are
    /// started while legacy Keychain interaction is enabled for this process.
    static func runHelper() -> Int32 {
        do {
            let target = try targetFromArguments()
            let settings = try LocalStore().loadSettings()
            let resolved = try resolve(target, settings: settings)
            try KeychainVault.enableInteractionForAuthorizationHelper()
            guard let snapshot = try KeychainClient.system.interactiveSnapshot(resolved.selector) else { return 4 }
            guard matches(snapshot.selector, resolved.selector) else { return 6 }
            let receipt = KeychainAuthorizationReceipt(
                persistentReference: snapshot.persistentReference,
                identity: try resolved.identity(snapshot.data)
            )
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(receipt))
            return 0
        } catch let error as KeychainAccessError where error.status == errSecUserCanceled {
            return 5
        } catch {
            return 6
        }
    }

    static func authorizeAndVerify(_ target: KeychainAuthorizationTarget, settings: Settings,
                                   client: KeychainClient) throws -> KeychainVerificationResult {
        let resolved = try resolve(target, settings: settings)
        guard client.usesSystemAuthorizationHelper else {
            return try client.authorizeAndVerify(resolved.selector, validate: resolved.identity)
        }
        guard let executable = Bundle.main.executableURL else {
            throw AppFailure.message("Keychain authorization helper is unavailable.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments(for: target)
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 4 { return .missing }
        guard process.terminationStatus == 0 else {
            throw KeychainAccessError(status: process.terminationStatus == 5 ? errSecUserCanceled : errSecAuthFailed)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let receipt = try JSONDecoder().decode(KeychainAuthorizationReceipt.self, from: data)
        guard let snapshot = try client.noninteractiveSnapshot(resolved.selector,
                                                               persistentReference: receipt.persistentReference) else {
            return .missing
        }
        guard matches(snapshot.selector, resolved.selector),
              snapshot.persistentReference == receipt.persistentReference else { return .changed }
        guard let identity = try? resolved.identity(snapshot.data) else { return .invalid }
        return identity == receipt.identity ? .verified : .changed
    }

    private struct ResolvedTarget {
        let selector: KeychainItemSelector
        let identity: (Data) throws -> String
    }

    private static func resolve(_ target: KeychainAuthorizationTarget,
                                settings: Settings) throws -> ResolvedTarget {
        switch target {
        case .subscriptionVault:
            let selector = KeychainItemSelector(service: KeychainVault.defaultService,
                                                account: SingleRecordVault.account)
            return ResolvedTarget(selector: selector, identity: KeychainVault.vaultRecordIdentity)
        case .claudeCode(let selector):
            let connector = CLIConnector(settings: settings)
            guard selector == (try connector.claudeKeychainSelector()) else { throw AppFailure.concurrentChange }
            return ResolvedTarget(selector: selector) { data in
                try connector.claudeCredentialIdentity(data, selector: selector)
            }
        }
    }

    private static func arguments(for target: KeychainAuthorizationTarget) -> [String] {
        switch target {
        case .subscriptionVault:
            return [flag, "vault"]
        case .claudeCode(let selector):
            return [flag, "claude", selector.service, selector.account,
                    selector.useDataProtectionKeychain ? "1" : "0"]
        }
    }

    private static func targetFromArguments() throws -> KeychainAuthorizationTarget {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { throw AppFailure.invalidCredential }
        let kind = CommandLine.arguments[index + 1]
        if kind == "vault" { return .subscriptionVault }
        guard kind == "claude", CommandLine.arguments.indices.contains(index + 4) else {
            throw AppFailure.invalidCredential
        }
        let selector = KeychainItemSelector(
            service: CommandLine.arguments[index + 2],
            account: CommandLine.arguments[index + 3],
            useDataProtectionKeychain: CommandLine.arguments[index + 4] == "1"
        )
        return .claudeCode(selector)
    }

    private static func matches(_ actual: KeychainItemSelector,
                                _ expected: KeychainItemSelector) -> Bool {
        actual.service == expected.service && actual.account == expected.account
            && (expected.accessGroup == nil || actual.accessGroup == expected.accessGroup)
            && actual.useDataProtectionKeychain == expected.useDataProtectionKeychain
    }
}
