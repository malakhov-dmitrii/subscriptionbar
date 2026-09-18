import SwiftUI
import SubscriptionCore

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            menuBarTab.tabItem { Label(model.t("Menu bar"), systemImage: "menubar.rectangle") }
            generalTab.tabItem { Label(model.t("General"), systemImage: "slider.horizontal.3") }
            accountsTab.tabItem { Label(model.t("Accounts"), systemImage: "person.2") }
            connectionsTab.tabItem { Label(model.t("Connections"), systemImage: "link") }
        }
        .frame(minWidth: 620, idealWidth: 640, maxWidth: 700, minHeight: 620, idealHeight: 660, maxHeight: .infinity)
        .disabled(model.busy)
        .environment(\.locale, model.locale)
        .safeAreaInset(edge: .top) { if model.previewOnly { previewNotice } }
        .onChange(of: model.settings.autoSwitch) { model.persist() }
        .onChange(of: model.settings.restartCodex) { model.persist() }
        .onDisappear { model.persist() }
        .task { await model.refreshConnectionStatus() }
    }

    private var previewNotice: some View {
        Label(model.t("Offline preview: changes are not saved."), systemImage: "eye")
            .font(.caption).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.yellow.opacity(0.25))
    }

    // MARK: Menu bar

    /// This tab used to miss `.formStyle(.grouped)`, which left it ungrouped,
    /// vertically centred and with the language label printed twice.
    private var menuBarTab: some View {
        Form {
            Section(model.t("Language")) {
                Picker(selection: Binding(get: { model.language }, set: { model.setLanguage($0) })) {
                    Text("Русский").tag(AppLanguage.ru)
                    Text("English").tag(AppLanguage.en)
                } label: {
                    Text(model.t("Interface language"))
                }
                Text(model.t("System menus use the selected language after restarting the app."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(model.t("Remaining usage in the menu bar")) {
                ForEach(Provider.allCases) { provider in
                    Toggle(isOn: Binding(get: { model.menuBarProviders.contains(provider) },
                                         set: { model.showInMenuBar(provider, $0) })) {
                        HStack {
                            Text(provider.name)
                            Spacer()
                            Text(MenuBarSummary.label(provider))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }.disabled(!model.settings.enabledProviders.contains(provider))
                }
                Text(model.t("Shows enabled services and active accounts. The percentage is the lowest remaining limit; balances use the service currency. “—” means no fresh data. Turn everything off to show only the icon."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if Provider.allCases.contains(where: { !model.settings.enabledProviders.contains($0) }) {
                    Text(model.t("Greyed out services are turned off in General."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(model.t("Preview")) {
                LabeledContent(model.t("Menu bar shows")) {
                    Text(model.menuBarText.isEmpty ? model.t("Icon only") : model.menuBarText)
                        .monospacedDigit()
                        .foregroundStyle(model.menuBarEntries.contains { $0.level == .critical } ? Color.red : .primary)
                }
                if model.menuBarText.count > 24 {
                    Label(model.t("This is long for the menu bar; macOS may hide other items."), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }.formStyle(.grouped)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section(model.t("Automatic switching")) {
                Toggle(model.t("Switch when the limit runs out"), isOn: $model.settings.autoSwitch)
                thresholdRow(model.t("Switch at or below"), value: Binding(
                    get: { model.settings.switchAt },
                    set: { model.setSwitchThreshold($0) }), range: 0...50, enabled: model.settings.autoSwitch)
                thresholdRow(model.t("Warn at or below"), value: Binding(
                    get: { model.settings.warnAt },
                    set: { model.setWarnThreshold($0) }), range: 1...80, enabled: true)
                Toggle(model.t("Allow restarting Codex"), isOn: $model.settings.restartCodex)
                Text(model.t("Uses fresh usage data. Set account priority in the Accounts tab. Automatic switching pauses after an error."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(model.t("Notifications")) {
                LabeledContent(model.t("Status")) {
                    switch model.notificationStatus {
                    case .allowed: Label(model.t("Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied: Label(model.t("Blocked in System Settings"), systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                    case .notAsked: Label(model.t("Not requested yet"), systemImage: "bell.slash").foregroundStyle(.secondary)
                    case .unknown: Text("—").foregroundStyle(.secondary)
                    }
                }
                if model.notificationStatus == .denied {
                    Button(model.t("Open System Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } else {
                    Button(model.t("Allow notifications")) { model.requestNotifications() }
                        .disabled(model.notificationStatus == .allowed)
                }
                Text(model.t("Used for switching results and for limits that ran out with no account left."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(model.t("Services")) {
                ForEach(Provider.allCases) { provider in
                    Toggle(provider.name, isOn: Binding(get: { model.settings.enabledProviders.contains(provider) },
                                                        set: { model.enable(provider, $0) }))
                }
                Text(model.t("Disabled services disappear from the dashboard and the menu bar. Their saved accounts are kept."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(model.t("Migrating from the old trackers")) {
                Button(model.t("Quit the three old trackers")) { model.confirmLegacyQuit = true }
                    .disabled(!model.credentialAccess.permitsPolling)
                Text(model.t("After checking usage, quits Claude Usage, Codex Account Switcher and Grok Usage. Your working clients stay open."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
        .confirmationDialog(model.t("Quit the three old trackers?"), isPresented: $model.confirmLegacyQuit) {
            Button(model.t("Quit them")) { Task { await model.closeLegacyTrackers() } }
            Button(model.t("Cancel"), role: .cancel) {}
        } message: {
            Text(model.t("Claude Usage, Codex Account Switcher and Grok Usage will be closed. Their macOS login settings are not changed."))
        }
    }

    private func thresholdRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, enabled: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(model.percent(value.wrappedValue) + "%").monospacedDigit().frame(minWidth: 40, alignment: .trailing)
                Stepper("", value: value, in: range, step: 1).labelsHidden()
                    .accessibilityLabel(title)
                    .accessibilityValue(model.percent(value.wrappedValue) + "%")
            }
        }.disabled(!enabled)
    }

    // MARK: Accounts

    private var accountsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(model.t("Order sets which account is tried next when one runs out."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.t("Add account")) { SubscriptionDelegate.showAddAccount() }
                }
                if model.settings.accounts.isEmpty {
                    Text(model.t("No accounts connected yet")).foregroundStyle(.secondary)
                }
                ForEach(Provider.allCases) { provider in
                    let accounts = model.settings.accounts.filter { $0.provider == provider }
                    if !accounts.isEmpty {
                        Text(provider.name).font(.headline)
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { position, account in
                            accountCard(account, position: position, total: accounts.count)
                        }
                    }
                }
            }.padding(20)
        }
        .confirmationDialog(model.t("Remove %@?", model.pendingDeleteLabel),
                            isPresented: Binding(get: { model.pendingDelete != nil },
                                                 set: { if !$0 { model.pendingDelete = nil } })) {
            Button(model.t("Remove account"), role: .destructive) {
                if let id = model.pendingDelete { model.pendingDelete = nil; Task { await model.delete(id) } }
            }
            Button(model.t("Cancel"), role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text(model.t("The saved credentials and browser sessions for this account are deleted from Keychain. The account itself is not affected."))
        }
    }

    @ViewBuilder private func accountCard(_ account: Account, position: Int, total: Int) -> some View {
        let isActive = model.settings.active[account.provider] == account.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(position + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                TextField(model.t("Account name"), text: Binding(
                    get: { account.label },
                    set: { model.rename(account.id, to: $0) }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    .accessibilityLabel(model.t("Account name"))
                if isActive {
                    Text(model.t("active")).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.2), in: Capsule())
                }
                Spacer()
                // Priority arrows are pointless with a single account; hide them.
                if total > 1 {
                    Button { model.move(account.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .help(model.t("Move up in priority")).accessibilityLabel(model.t("Move up in priority"))
                        .disabled(position == 0)
                    Button { model.move(account.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .help(model.t("Move down in priority")).accessibilityLabel(model.t("Move down in priority"))
                        .disabled(position == total - 1)
                }
                Button(role: .destructive) { model.pendingDelete = account.id } label: { Image(systemName: "trash") }
                    .help(model.t("Remove account")).accessibilityLabel(model.t("Remove account"))
                    .disabled(model.busy || model.previewOnly)
            }
            if account.provider.hasCLIProfile {
                Toggle(model.t("Switch the saved browser session"), isOn: Binding(
                    get: { model.settings.accounts.first(where: { $0.id == account.id })?.browserEnabled ?? false },
                    set: { model.browser(account.id, enabled: $0) }))
                Label(model.browserAccounts.contains(account.id) ? model.t("Browser session saved")
                      : model.t("Save a session using the browser extension"),
                      systemImage: model.browserAccounts.contains(account.id) ? "checkmark.circle" : "circle.dashed")
                    .font(.caption).foregroundStyle(model.browserAccounts.contains(account.id) ? .green : .secondary)
            }
            if account.provider.usesBalance, let index = model.settings.accounts.firstIndex(where: { $0.id == account.id }) {
                HStack {
                    Text(model.t("Warn when balance ≤"))
                    TextField(model.t("Threshold"), value: $model.settings.accounts[index].balanceThreshold, format: .number)
                        .frame(width: 70).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(model.t("Warn when balance ≤"))
                    Text(model.balanceCurrency(account)).foregroundStyle(.secondary)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Connections

    private var connectionsTab: some View {
        Form {
            Section(model.t("Browser")) {
                LabeledContent(model.t("Connection")) {
                    if model.nativeHostInstalled {
                        Label(model.browserExtensionReady ? model.t("Extension connected") : model.t("Installed · no browser reporting"),
                              systemImage: model.browserExtensionReady ? "checkmark.circle.fill" : "clock")
                            .foregroundStyle(model.browserExtensionReady ? .green : .orange)
                    } else {
                        Label(model.t("Not set up"), systemImage: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                Text(model.t("Chrome, Edge and Brave. The extension saves the selected session in Keychain and applies it when the app requests it."))
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.t("Step 1: run the installer once so the browser can reach the app."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.t("Set up browser connection…")) { openResource("install-browser-host.command") }
                Text(model.t("Step 2: open chrome://extensions → Developer mode → Load unpacked, and pick this folder."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(model.t("Open extension folder")) { openResource("browser-extension") }
                Text(model.t("Step 3: in the extension, choose an account and save its current session."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(model.t("Firefox uses the firefox subfolder of the extension and needs its own unsigned install step."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(model.t("Clients")) {
                clientRow("Claude Code", model.t("Keychain + credentials + profile"), warning: false)
                clientRow("Codex Desktop", model.t("Change sign-in and restart"), warning: false)
                clientRow("Grok CLI", model.t("Sign-in file; running process unverified"), warning: true)
                Text(model.t("Claude Desktop, ChatGPT Desktop and Safari are not integrated. Running CLI processes may retain the old sign-in in memory. Task resumption is not verified."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(model.t("CLI folders")) {
                pathRow("Claude", text: $model.settings.claudeHome)
                pathRow("Codex", text: $model.settings.codexHome)
                pathRow("Grok", text: $model.settings.grokHome)
                Text(model.t("Paths must match the configuration of the clients you launch."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped)
    }

    /// Read-only facts and editable fields looked identical in a grouped form.
    private func clientRow(_ name: String, _ value: String, warning: Bool) -> some View {
        LabeledContent(name) {
            HStack(spacing: 5) {
                if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                Text(value).foregroundStyle(.secondary)
            }
        }
    }

    private func pathRow(_ name: String, text: Binding<String>) -> some View {
        let exists = model.pathExists(text.wrappedValue)
        return LabeledContent(name) {
            HStack(spacing: 6) {
                TextField(name, text: text)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 220)
                    .accessibilityLabel(model.t("%@ folder", name))
                Image(systemName: exists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(exists ? .green : .orange)
                    .help(exists ? model.t("Folder found") : model.t("Folder not found"))
                    .accessibilityLabel(exists ? model.t("Folder found") : model.t("Folder not found"))
            }
        }
    }

    private func openResource(_ name: String) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path) else {
            model.lastResult = model.t("Open the packaged SubscriptionBar.app to install the extension."); return
        }
        NSWorkspace.shared.open(url)
    }
}
