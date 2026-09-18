import SwiftUI
import SubscriptionCore

struct DashboardView: View {
    @ObservedObject var model: AppModel
    private var visibleProviders: [Provider] {
        Provider.allCases.filter { model.settings.enabledProviders.contains($0) && !$0.usesBalance }
    }
    private var balanceProviders: [Provider] {
        Provider.allCases.filter { model.settings.enabledProviders.contains($0) && $0.usesBalance }
    }
    /// The access banner is about moving existing secrets. With nothing saved
    /// there is nothing to move, and a security prompt is the wrong first screen.
    private var showsAccessBanner: Bool {
        model.credentialAccess != .ready && !model.settings.accounts.isEmpty
    }
    private var showsOnboarding: Bool {
        model.settings.accounts.isEmpty && !model.previewOnly
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.t("Subscriptions")).font(.title2.weight(.semibold))
                    Text(model.demo ? model.t("Demo · sample data")
                         : model.previewOnly ? model.t("Saved data · offline preview")
                         : model.t("Percentages show how much is left"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16)
                    .opacity(model.busy ? 1 : 0)
                    .accessibilityHidden(!model.busy)
                // `.labelStyle(.iconOnly)` keeps the glyph but gives the button a real
                // title; `.accessibilityLabel` on an icon Button does not reach VoiceOver.
                Button { Task { await model.refresh() } } label: {
                    Label(model.t("Refresh usage"), systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                    .buttonStyle(.borderless).help(model.t("Refresh usage"))
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.busy || !model.credentialAccess.permitsPolling)
                Button { SubscriptionDelegate.showPreferences() } label: {
                    Label(model.t("Settings"), systemImage: "gearshape").labelStyle(.iconOnly)
                }
                    .buttonStyle(.borderless).help(model.t("Settings"))
            }.padding(14)
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    if showsAccessBanner { accessBanner }
                    if let reason = model.settings.automationPausedReason { pausedBanner(reason) }
                    if showsOnboarding { onboarding }
                    else {
                        VStack(spacing: 0) {
                            ForEach(visibleProviders) { provider in
                                CompactProviderRow(provider: provider, model: model)
                                Divider().padding(.horizontal, 12)
                            }
                            if !balanceProviders.isEmpty { CompactBalances(providers: balanceProviders, model: model) }
                        }
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !model.lastResult.isEmpty { lastEvent }
                }.padding(10)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Label(footerText, systemImage: footerIcon)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { SubscriptionDelegate.showAddAccount() } label: { Image(systemName: "plus") }
                    .help(model.t("Add account")).accessibilityLabel(model.t("Add account"))
                    .disabled(!model.credentialAccess.permitsPolling && !model.previewOnly)
                Divider().frame(height: 14)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .help(model.t("Quit SubscriptionBar")).accessibilityLabel(model.t("Quit SubscriptionBar"))
            }.buttonStyle(.borderless).padding(12)
        }
        .frame(minWidth: 430, idealWidth: 430, maxWidth: 620, minHeight: 420, idealHeight: 470, maxHeight: .infinity)
        .environment(\.locale, model.locale)
        .background(.background)
    }

    private var footerText: String {
        if !model.credentialAccess.permitsPolling { return model.t("Updates paused") }
        guard model.settings.autoSwitch else { return model.t("Auto-switch off") }
        return model.t("Auto-switch at ≤%@%%", model.percent(model.settings.switchAt))
    }
    private var footerIcon: String {
        model.settings.autoSwitch && model.credentialAccess.permitsPolling ? "arrow.triangle.2.circlepath" : "pause"
    }

    private var accessBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.credentialAccess.title, systemImage: "lock.shield").font(.headline)
            Text(model.credentialAccess.message).font(.caption).fixedSize(horizontal: false, vertical: true)
            if case .migration(let done, let total) = model.credentialAccess, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).progressViewStyle(.linear)
            }
            if let title = model.credentialAccess.button {
                Button(title) { Task { await model.authorizeAccounts() } }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pausedBanner(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.t("Switching paused"), systemImage: "pause.circle").font(.headline)
            Text(model.message(reason)).font(.caption).fixedSize(horizontal: false, vertical: true)
            Button(model.t("Resume after checking sign-in")) { model.resume() }.disabled(model.busy)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// First run has nothing to show, so it explains the one next step instead of
    /// a list of services that are all "not connected".
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.t("No accounts connected yet"), systemImage: "person.badge.plus").font(.headline)
            Text(model.t("SubscriptionBar reads the limits of accounts you are already signed into. Sign in to a client, then save that account here. Repeat for a second account to enable switching."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.t("Connect the first account")) { SubscriptionDelegate.showAddAccount() }
                    .buttonStyle(.borderedProminent)
                Button(model.t("Choose services")) { SubscriptionDelegate.showPreferences() }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The outcome of switching, saving and permission prompts used to live in a
    /// collapsed disclosure group, where nobody saw it.
    private var lastEvent: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
            Text(model.message(model.lastResult)).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button { model.lastResult = "" } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).font(.caption2)
                .help(model.t("Dismiss")).accessibilityLabel(model.t("Dismiss"))
        }.padding(10)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ProviderCard: View {
    let provider: Provider
    @ObservedObject var model: AppModel
    @State private var pendingSwitch: Account?
    private var accounts: [Account] { model.settings.accounts.filter { $0.provider == provider } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.name).font(.headline)
                Spacer()
                Button { NSWorkspace.shared.open(provider.website) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.borderless).help(model.t("Open %@", provider.name))
                    .accessibilityLabel(model.t("Open %@", provider.name))
            }
            if accounts.isEmpty {
                HStack {
                    Text(model.t("Not connected")).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.t("Connect")) { SubscriptionDelegate.showAddAccount(provider: provider) }.controlSize(.small)
                }.font(.callout)
            }
            ForEach(accounts) { account in
                accountSection(account)
                if account.id != accounts.last?.id { Divider() }
            }
        }.padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .confirmationDialog(model.t("Switch to %@?", pendingSwitch?.label ?? ""),
                                isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
                                presenting: pendingSwitch) { target in
                Button(model.t("Switch account")) {
                    pendingSwitch = nil
                    Task { await model.switchAccount(target.id) }
                }
                Button(model.t("Cancel"), role: .cancel) { pendingSwitch = nil }
            } message: { target in
                Text(switchWarning(target))
            }
    }

    private func switchWarning(_ target: Account) -> String {
        var lines = [model.t("This rewrites the sign-in used by the client on this Mac.")]
        if provider == .codex { lines.append(model.t("Codex will be asked to quit and reopen.")) }
        if target.browserEnabled { lines.append(model.t("The saved browser session will be applied.")) }
        return lines.joined(separator: " ")
    }

    @ViewBuilder private func accountSection(_ account: Account) -> some View {
        let isActive = model.settings.active[provider] == account.id
        let snapshot = model.readings[account.id]
        let stale = snapshot.map { !$0.isFresh(at: model.now) } ?? true || model.errors[account.id] != nil
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6).accessibilityHidden(true)
                Text(model.accountLabel(account)).font(.subheadline.weight(.medium))
                if isActive { Text(model.t("active")).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if account.monitoringOnly == true { Text(model.t("monitoring only")).font(.caption2).foregroundStyle(.secondary) }
                if !isActive && account.canSwitch {
                    Button(model.t("Switch")) { pendingSwitch = account }
                        .controlSize(.small)
                        .disabled(model.busy || model.errors[account.id] != nil || !model.credentialAccess.permitsPolling)
                }
            }
            if let snapshot {
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                    let level: UsageLevel = stale ? .stale : model.settings.level(window.remaining, stale: false)
                    VStack(spacing: 4) {
                        HStack {
                            Text(model.message(window.name)).foregroundStyle(.secondary)
                            Spacer()
                            Text(model.t("%@%% remaining", model.percent(window.remaining)))
                                .monospacedDigit().fontWeight(.medium).foregroundStyle(level.textTint)
                        }.font(.caption)
                        ProgressView(value: max(0, min(window.remaining, 100)), total: 100).tint(level.tint)
                        if let reset = window.resetsAt {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(model.t("Resets %@ · %@", model.date(reset),
                                             ResetCountdown.text(until: reset, now: context.date, language: model.language)))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                }
                ForEach(Array(snapshot.balances.enumerated()), id: \.offset) { _, balance in
                    Text(balance.available.formatted(.currency(code: balance.currency).locale(model.locale)))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                }
                if stale {
                    Label(model.t("Last known data · currently unverified"), systemImage: "clock.badge.exclamationmark")
                        .font(.caption2).foregroundStyle(.orange)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(model.t("Updated %@", model.relative(snapshot.fetchedAt, now: context.date)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if model.errors[account.id] == nil {
                Text(model.t("Waiting for usage…")).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errors[account.id] {
                Text(model.message(error)).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AddAccountView: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void
    @State private var provider: Provider
    @State private var label = ""
    @State private var apiKey = ""
    @State private var formError: String?
    @FocusState private var nameFocused: Bool
    init(model: AppModel, provider: Provider = .claude, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _provider = State(initialValue: provider)
    }
    private var needsKey: Bool { !provider.hasCLIProfile && provider != .cursor }
    private var blocker: String? {
        if model.previewOnly { return model.t("Form preview: saving is disabled.") }
        if !model.credentialAccess.permitsPolling { return model.t("Allow account access in the main window first.") }
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return model.t("Enter a name so you can tell this account from the others.") }
        if needsKey && apiKey.isEmpty { return model.t("Paste the key for this service.") }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("Add account")).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                Picker(model.t("Service"), selection: $provider) { ForEach(Provider.allCases) { Text($0.name).tag($0) } }
                    .frame(maxWidth: 300)
                // A bare TextField renders its title as a placeholder that disappears
                // once the field has held focus, so the label is explicit.
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("Account name")).font(.callout)
                    TextField(model.t("Name, e.g. Personal"), text: $label).focused($nameFocused)
                    Text(model.t("Only you see this name. It does not have to match the service."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if needsKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider == .openRouter ? model.t("Management key") : model.t("API key")).font(.callout)
                        SecureField(provider == .openRouter ? model.t("Management key") : model.t("API key"), text: $apiKey)
                        HStack(spacing: 6) {
                            Text(model.t("The key is saved in Keychain. This connection shows usage or balance; keys in other clients are not changed."))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        Button(model.t("Where to get the key")) { NSWorkspace.shared.open(provider.website) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            Text(guidance).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let formError {
                Text(model.message(formError)).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let blocker, formError == nil {
                Text(blocker).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button(model.t("Cancel")) { apiKey = ""; onClose() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.t("Save account")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocker != nil || model.busy)
            }
        // A fixed height keeps the window from jumping when the service changes.
        }.padding(24).frame(width: 470, height: 430, alignment: .topLeading).textFieldStyle(.roundedBorder)
        .environment(\.locale, model.locale)
            .onAppear { nameFocused = true }
            .onChange(of: provider) { apiKey = ""; formError = nil }
    }
    private var guidance: String {
        if provider == .cursor {
            return model.t("Connect the account signed into Cursor on this Mac. Usage is read-only; account switching is not enabled.")
        }
        if provider.hasCLIProfile {
            let client = provider == .claude ? "Claude Code" : provider == .codex ? "Codex" : "Grok CLI"
            return model.t("Sign in to %@, then save the current account here. Repeat sign-in and saving for another account.", client)
        }
        if provider == .kimiCode {
            return model.t("Use a Kimi Code subscription key, not a Moonshot API key. Usage monitoring only.")
        }
        return model.t("Usage monitoring only. This service is not switched automatically.")
    }
    private func save() {
        Task {
            let success = await model.add(provider: provider, label: label, apiKey: apiKey)
            apiKey = ""
            if success { onClose(); await model.refresh() }
            else { formError = model.lastResult }
        }
    }
}
