import AppKit
import SwiftUI
import SubscriptionCore

enum CodexReauthenticationPhase: Sendable, Equatable {
    case ready
    case starting
    case awaiting(CodexLoginInstructions)
    case checking
    case saving
    case switching
    case cancelling
    case succeeded(String)
    case failed(String)
}

/// Presentation only. The parent owns the login attempt and native window lifecycle.
struct CodexReauthenticationView: View {
    let accountName: String
    let profileName: String?
    let phase: CodexReauthenticationPhase
    let onStart: (CodexLoginMethod, Bool) -> Void
    let onCancel: () -> Void
    let onClose: () -> Void
    let onOpen: (URL) -> Void
    @State private var switchAfterSignIn = false
    @State private var copiedCode = false

    init(accountName: String, profileName: String?, phase: CodexReauthenticationPhase,
         onStart: @escaping (CodexLoginMethod, Bool) -> Void,
         onCancel: @escaping () -> Void, onClose: @escaping () -> Void,
         onOpen: @escaping (URL) -> Void) {
        self.accountName = accountName
        self.profileName = profileName
        self.phase = phase
        self.onStart = onStart
        self.onCancel = onCancel
        self.onClose = onClose
        self.onOpen = onOpen
    }

    private var canChoose: Bool {
        switch phase { case .ready, .failed: true; default: false }
    }
    private var isSucceeded: Bool {
        if case .succeeded = phase { true } else { false }
    }
    private var wantsSwitch: Bool { profileName != nil && switchAfterSignIn }
    private var primaryTitle: String {
        if wantsSwitch { return L10n.ui("Sign in and switch") }
        if case .failed = phase { return L10n.ui("Retry sign-in") }
        return L10n.ui("Sign in again")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isSucceeded ? L10n.ui("Sign-in saved") : L10n.ui("Sign in again"))
                    .font(.title2.weight(.semibold))
                Text(accountName).font(.headline).lineLimit(2).help(accountName)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            if !isSucceeded {
                Toggle(isOn: $switchAfterSignIn) {
                    Text(profileName.map { L10n.ui("Switch in %@ after sign-in", $0) }
                         ?? L10n.ui("Switch after sign-in"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .disabled(!canChoose || profileName == nil)
                .help(profileName == nil ? L10n.ui("Select a configured Codex profile before switching.")
                      : L10n.ui("Only the selected Codex profile will be asked to quit and reopen: %@.", profileName ?? ""))
            }
            actions
        }
        .padding(24)
        .frame(width: 490, height: 370, alignment: .topLeading)
        .onChange(of: phase) { copiedCode = false }
        .onChange(of: profileName) { switchAfterSignIn = false }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .ready:
            Text(L10n.ui("Sign in with this account and its saved workspace."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .starting:
            progress("Starting sign-in…")
        case .awaiting(let instructions):
            if let code = instructions.userCode {
                Text(L10n.ui("Enter this code in your browser."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) {
                    Text(code).font(.title3.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(L10n.ui("Sign-in code")).accessibilityValue(code)
                    Spacer(minLength: 0)
                    Button(L10n.ui(copiedCode ? "Copied" : "Copy code")) { copy(code) }
                        .accessibilityLabel(L10n.ui("Copy code"))
                }
                .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(L10n.ui("Complete sign-in in your browser."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // The full OAuth URL can contain login secrets. Show only the destination host.
            if let host = instructions.url.host {
                Text(host).font(.caption).foregroundStyle(.secondary)
            }
        case .checking:
            progress("Checking account and limits…")
        case .saving:
            progress("Saving sign-in…")
        case .switching:
            progress("Switching selected profile…")
        case .cancelling:
            progress("Cancelling sign-in…")
        case .succeeded(let message):
            Label(L10n.translate(message), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(L10n.translate(message), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .ready, .failed:
            HStack {
                Button(L10n.ui("Close"), action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.ui("Sign in with code")) { onStart(.deviceCode, wantsSwitch) }
                Button(primaryTitle) { onStart(.browser, wantsSwitch) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        case .awaiting(let instructions):
            HStack {
                Button(L10n.ui("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.ui("Open browser")) { onOpen(instructions.url) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        case .starting, .checking:
            HStack {
                Button(L10n.ui("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
            }
        case .saving, .switching, .cancelling:
            HStack {
                Button(L10n.ui("Close"), action: onClose).disabled(true)
                Spacer()
            }
        case .succeeded:
            HStack {
                Spacer()
                Button(L10n.ui("Close"), action: onClose)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progress(_ key: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10n.ui(key)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        copiedCode = NSPasteboard.general.setString(code, forType: .string)
    }
}
