import Foundation
import SubscriptionCore

extension AccountRuntime {
    private var codexReauthenticationService: CodexReauthentication {
        CodexReauthentication(store: store, vault: vault, fetch: { [fetchUsage] credential in
            try await fetchUsage(CodexAccountRecovery.usageCredential(credential))
        })
    }

    func prepareCodexReauthentication(accountID: UUID, settings: Settings, expected: Data?) throws -> CodexReauthenticationPlan {
        try codexReauthenticationService.prepare(accountID: accountID, settings: settings, expected: expected)
    }

    func validateCodexReauthentication(_ plan: CodexReauthenticationPlan,
                                      candidate: CredentialEnvelope) async throws -> CodexReauthenticationValidation {
        try await codexReauthenticationService.validate(plan, candidate: candidate)
    }

    func commitCodexReauthentication(_ validation: CodexReauthenticationValidation) async throws -> CodexRecoveryResult {
        try await codexReauthenticationService.commit(validation)
    }
}
