import AppKit
import Foundation
import SubscriptionCore

@MainActor
final class CodexReauthenticationController: ObservableObject {
    @Published private(set) var phase = CodexReauthenticationPhase.ready
    let accountName: String
    let profileName: String?
    private weak var model: AppModel?
    private let account: Account
    private let selectedProfile: CodexClientProfile?
    private let initialSettingsData: Data?
    private let session: CodexLoginSession
    private let openBrowser: (URL) -> Void
    private var generation = UUID()
    private var ownsBusy = true
    private var task: Task<Void, Never>?
    private var cancellationTask: Task<Bool, Never>?
    private var window: CodexReauthenticationWindow?

    init(model: AppModel, account: Account, session: CodexLoginSession, openBrowser: @escaping (URL) -> Void) {
        self.model = model
        self.account = account
        accountName = model.accountLabel(account)
        selectedProfile = model.settings.selectedCodexProfile
        profileName = selectedProfile?.name
        initialSettingsData = model.settingsData
        self.session = session
        self.openBrowser = openBrowser
    }

    func showWindow() {
        if window == nil { window = CodexReauthenticationWindow(controller: self) }
        window?.show()
    }

    func start(method: CodexLoginMethod, switchAfterSignIn: Bool) {
        guard let model, model.codexReauthentication === self else { return }
        switch phase { case .ready, .failed: break; default: return }
        generation = UUID()
        let attempt = generation
        model.busy = true
        ownsBusy = true
        phase = .starting
        task = Task { [self] in
            await run(attempt: attempt, method: method, switchAfterSignIn: switchAfterSignIn)
        }
    }

    func open(_ url: URL) {
        guard case .awaiting(let instructions) = phase, instructions.url == url else { return }
        if model?.demo == true {
            succeed(L10n.ui("Demo: sign-in completed. No accounts were changed."))
            return
        }
        guard (try? CodexLoginProtocol.trustedURL(url.absoluteString)) != nil else { return }
        openBrowser(url)
    }

    /// Returns true only when the native window may close immediately.
    @discardableResult
    func requestClose() -> Bool {
        switch phase {
        case .saving, .switching, .cancelling: return false
        case .starting, .awaiting, .checking:
            cancel()
            return false
        case .ready, .failed, .succeeded:
            guard session.isIdle else { cancel(); return false }
            dismiss()
            return true
        }
    }

    func cancel() {
        switch phase {
        case .saving, .switching, .cancelling: return
        default: break
        }
        generation = UUID() // Invalidate candidate delivery before suspending.
        phase = .cancelling
        let running = task
        task = nil
        running?.cancel()
        cancellationTask = Task { [self] in
            defer { cancellationTask = nil }
            await session.cancel()
            await running?.value
            guard session.isIdle else {
                phase = .failed(CodexLoginError.stopFailed.localizedDescription)
                return false
            }
            dismiss()
            return true
        }
    }

    /// App termination must wait for the owned helper and staging cleanup, not
    /// merely for the window to disappear. Atomic save/native handoff cannot quit.
    func prepareForAppTermination() async -> Bool {
        switch phase {
        case .saving, .switching: return false
        default: break
        }
        if let cancellationTask { return await cancellationTask.value }
        cancel()
        if let cancellationTask { return await cancellationTask.value }
        guard session.isIdle else { return false }
        dismiss()
        return true
    }

    private func run(attempt: UUID, method: CodexLoginMethod, switchAfterSignIn: Bool) async {
        guard let model else { return }
        var didSave = false
        do {
            if !session.isIdle { await session.cancel() }
            guard session.isIdle else { throw CodexLoginError.stopFailed }
            try check(attempt)
            guard model.settingsData == initialSettingsData,
                  model.settings.accounts.first(where: { $0.id == account.id }) == account,
                  model.settings.selectedCodexProfile == selectedProfile,
                  !switchAfterSignIn || selectedProfile != nil else { throw AppFailure.concurrentChange }
            if model.demo {
                guard let url = URL(string: "https://auth.openai.com/codex/device") else { throw CodexLoginError.unsafeURL }
                phase = .awaiting(CodexLoginInstructions(loginID: "demo", url: url,
                    userCode: method == .deviceCode ? "DEMO-CODE" : nil))
                return
            }
            let plan = try await model.runtime.prepareCodexReauthentication(accountID: account.id,
                settings: model.settings, expected: model.settingsData)
            try check(attempt)
            guard plan.selectedProfile == selectedProfile else { throw AppFailure.concurrentChange }
            for try await event in session.start(method: method, workspaceID: plan.workspaceID,
                                                 applicationPath: plan.selectedProfile?.applicationPath) {
                try check(attempt)
                switch event {
                case .instructions(let instructions):
                    phase = .awaiting(instructions)
                    if method == .browser { open(instructions.url) }
                case .authenticated(let candidate):
                    phase = .checking
                    let validation = try await model.runtime.validateCodexReauthentication(plan, candidate: candidate)
                    try check(attempt)
                    guard model.settings.selectedCodexProfile == plan.selectedProfile else { throw AppFailure.concurrentChange }
                    // No suspension between the last cancellation check and entering
                    // the non-cancellable atomic-save boundary.
                    phase = .saving
                    let result = try await model.runtime.commitCodexReauthentication(validation)
                    didSave = true
                    model.settings = result.settings
                    model.settingsData = result.settingsData
                    model.publishReading(result.reading, for: result.accountID)
                    if switchAfterSignIn {
                        guard model.settings.selectedCodexProfile == plan.selectedProfile,
                              let target = model.settings.accounts.first(where: { $0.id == result.accountID }) else {
                            throw AppFailure.concurrentChange
                        }
                        phase = .switching
                        let switched = await model.performCodexSwitch(target, reinstallCurrent: true)
                        if switched { succeed(model.lastResult) }
                        else { savedButNotSwitched(model.lastResult) }
                    } else {
                        succeed(L10n.ui("Sign-in updated: %@.", accountName))
                    }
                    return
                }
            }
            throw CodexLoginError.failed
        } catch {
            guard generation == attempt else { return }
            if didSave {
                savedButNotSwitched(model.errorText(error))
                return
            }
            await session.cancel()
            guard generation == attempt else { return }
            model.reloadCodexSettings()
            if !session.isIdle {
                phase = .failed(CodexLoginError.stopFailed.localizedDescription)
            } else if let loginError = error as? CodexLoginError {
                phase = .failed(loginError.localizedDescription)
                model.setResult(loginError.localizedDescription)
            } else {
                model.recordOperationFailure(error)
                phase = .failed(model.lastResult)
            }
        }
    }

    private func check(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt, model?.codexReauthentication === self else { throw CancellationError() }
    }

    private func succeed(_ message: String) {
        phase = .succeeded(message)
        model?.setResult(message)
        releaseBusy()
        task = nil
    }

    private func savedButNotSwitched(_ detail: String) {
        let message = L10n.ui("Sign-in saved, but switching the selected profile failed.")
        succeed(detail.isEmpty ? message : message + "\n" + detail)
    }

    private func dismiss() {
        guard session.isIdle else { return }
        if model?.codexReauthentication === self {
            model?.codexReauthentication = nil
            releaseBusy()
        }
        let closing = window
        window = nil
        closing?.closeConfirmed()
    }

    private func releaseBusy() {
        guard ownsBusy else { return }
        model?.busy = false
        ownsBusy = false
    }
}

extension AppModel {
    @discardableResult
    func beginCodexReauthentication(_ accountID: UUID, session: CodexLoginSession? = nil,
        openBrowser: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        presentWindow: Bool = true) -> CodexReauthenticationController? {
        if let current = codexReauthentication {
            if presentWindow { current.showWindow() }
            return current
        }
        guard !busy, !previewOnly, credentialAccess.permitsPolling,
              let account = settings.accounts.first(where: { $0.id == accountID }),
              account.provider == .codex, account.canSwitch else { return nil }
        let controller = CodexReauthenticationController(model: self, account: account,
            session: session ?? CodexLoginSession(), openBrowser: openBrowser)
        codexReauthentication = controller
        busy = true
        if presentWindow { controller.showWindow() }
        return controller
    }
}
