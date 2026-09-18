import SwiftUI
import UserNotifications
import SubscriptionCore

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = Settings()
    @Published var readings: [UUID: UsageSnapshot] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var browserAccounts: Set<UUID> = []
    @Published var busy = false
    @Published var lastResult = ""
    @Published var now = Date()
    @Published var credentialAccess: CredentialAccess = .checking
    @Published var notificationStatus: NotificationStatus = .unknown
    @Published var browserExtensionReady = false
    @Published var nativeHostInstalled = false
    @Published var pendingDelete: UUID?
    @Published var confirmLegacyQuit = false

    enum NotificationStatus: Sendable { case unknown, notAsked, allowed, denied }
    let demo: Bool
    let previewOnly: Bool
    private let store = LocalStore()
    private let runtime = AccountRuntime()
    private var settingsData: Data?
    private var pollTask: Task<Void, Never>?
    private var notifications: [Provider: String] = [:]

    /// The icon must react to the thing the product exists for: a limit about to run out.
    var needsAttention: Bool {
        !errors.isEmpty || settings.automationPausedReason != nil
            || menuBarEntries.contains { $0.level == .critical }
            || providerLevels.values.contains(.critical)
    }
    var menuBarProviders: Set<Provider> { settings.menuBarProviders ?? [.claude, .codex, .grok] }
    var menuBarEntries: [MenuBarEntry] {
        Provider.allCases.filter { menuBarProviders.contains($0) && settings.enabledProviders.contains($0) }.map { provider in
            let id = settings.active[provider]
            let failed = !credentialAccess.permitsPolling || id.map { errors[$0] != nil } == true
            let snapshot = id.flatMap { readings[$0] }
            let account = id.flatMap { active in settings.accounts.first { $0.id == active } }
            return MenuBarEntry(provider: provider, label: MenuBarSummary.label(provider),
                                value: MenuBarSummary.value(snapshot, failed: failed, now: now),
                                level: MenuBarSummary.level(snapshot, failed: failed, account: account,
                                                            settings: settings, now: now))
        }
    }
    var menuBarText: String { menuBarEntries.map(\.text).joined(separator: " ") }
    var menuBarAccessibilitySummary: String {
        let parts = menuBarEntries.map { entry in
            entry.provider.name + " " + (entry.value == "—" ? t("no fresh data") : t("%@ remaining", entry.value))
        }
        return (["SubscriptionBar"] + parts + (needsAttention ? [t("needs attention")] : [])).joined(separator: ", ")
    }
    /// Severity per provider, shared by the compact row, the card and the icon.
    var providerLevels: [Provider: UsageLevel] {
        var result: [Provider: UsageLevel] = [:]
        for provider in Provider.allCases where settings.enabledProviders.contains(provider) {
            guard let id = settings.active[provider] else { continue }
            let failed = !credentialAccess.permitsPolling || errors[id] != nil
            let account = settings.accounts.first { $0.id == id }
            result[provider] = MenuBarSummary.level(readings[id], failed: failed, account: account,
                                                    settings: settings, now: now)
        }
        return result
    }
    func showInMenuBar(_ provider: Provider, _ enabled: Bool) {
        var selected = menuBarProviders
        if enabled { selected.insert(provider) } else { selected.remove(provider) }
        settings.menuBarProviders = selected
        persist()
    }
    init(demo: Bool, previewOnly: Bool = false) {
        self.demo = demo
        self.previewOnly = previewOnly
        // Demo used to leave L10n on the stored language while the views read
        // settings.language, so the window mixed two languages.
        let startup = (try? store.loadSettings().language) ?? AppLanguage.preferred
        L10n.language = startup
        if demo { settings.language = startup; loadDemo(); credentialAccess = .ready }
        else {
            do {
                settingsData = try SecureFiles.read(store.settingsURL)
                settings = try store.loadSettings()
                if let cacheData = try SecureFiles.read(store.root.appendingPathComponent("usage-cache.json")),
                   let cache = try? JSONDecoder().decode(LiveCache.self, from: cacheData) {
                    readings = cache.readings; errors = cache.errors
                }
                if settingsData == nil {
                    let environment = ProcessInfo.processInfo.environment
                    settings.claudeHome = environment["CLAUDE_CONFIG_DIR"] ?? settings.claudeHome
                    settings.codexHome = environment["CODEX_HOME"] ?? settings.codexHome
                }
            } catch { lastResult = errorText(error); settings.automationPausedReason = t("Settings could not be loaded.") }
            if previewOnly { credentialAccess = .preview; return }
            pollTask = Task { [weak self] in
                guard let self else { return }
                if self.settings.vaultSetupComplete == true {
                    self.credentialAccess = await self.runtime.accessStatus(settings: self.settings)
                } else if self.settings.accounts.isEmpty {
                    // Nothing saved yet: there is no vault to unlock and nothing to migrate.
                    self.credentialAccess = .ready
                } else {
                    // First launch/migration never touches Keychain until the user acts.
                    self.credentialAccess = .locked
                }
                while !Task.isCancelled {
                    if self.credentialAccess.permitsPolling { await self.refresh() }
                    await self.refreshConnectionStatus()
                    self.now = Date()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
    func persist() {
        guard !demo, !previewOnly else { return }
        do { settingsData = try store.saveSettings(settings, expected: settingsData) }
        catch { settings.automationPausedReason = t("Cannot save settings."); lastResult = errorText(error) }
    }
    private func saveOrThrow() throws {
        if !demo && !previewOnly { settingsData = try store.saveSettings(settings, expected: settingsData) }
    }
    func add(provider: Provider, label: String, apiKey: String) async -> Bool {
        guard !busy, !previewOnly, credentialAccess.permitsPolling else { return false }
        busy = true; defer { busy = false }
        do {
            if demo { lastResult = t("Demo: accounts are not saved."); return true }
            let credentials = try await runtime.capture(provider: provider, settings: settings, apiKey: apiKey)
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLabel.isEmpty, cleanLabel.count <= 80 else { throw AppFailure.message(t("Enter an account name (up to 80 characters).")) }
            if let existing = settings.accounts.first(where: { $0.provider == provider && $0.identity == credentials.identity }) {
                try await runtime.save(account: existing, credential: credentials)
                settings.active[provider] = existing.id
                lastResult = t("Sign-in updated: %@.", existing.label)
            } else {
                let account = Account(provider: provider, label: cleanLabel, identity: credentials.identity)
                try await runtime.save(account: account, credential: credentials)
                settings.accounts.append(account)
                settings.active[provider] = account.id
                let wasOff = !settings.enabledProviders.contains(provider)
                settings.enabledProviders.insert(provider)
                lastResult = t("Added %@: %@.", provider.name, account.label)
                // Turning a service back on is a settings change; say so instead of doing it quietly.
                if wasOff { lastResult += " " + t("%@ was switched back on in Settings.", provider.name) }
            }
            try saveOrThrow()
            return true
        } catch { lastResult = errorText(error); return false }
    }
    func refresh() async {
        guard !busy, !demo, !previewOnly, credentialAccess.permitsPolling else { return }
        busy = true; defer { busy = false; now = Date() }
        let accounts = settings.accounts.filter { $0.enabled && settings.enabledProviders.contains($0.provider) }
        let currentSettings = settings
        await withTaskGroup(of: (UUID, Result<UsageSnapshot, Error>, Bool).self) { group in
            for account in accounts {
                group.addTask { [runtime] in
                    let result: Result<UsageSnapshot, Error>
                    do { result = .success(try await runtime.fetch(account: account, settings: currentSettings)) }
                    catch { result = .failure(error) }
                    return (account.id, result, await runtime.hasBrowserSession(account.id))
                }
            }
            for await (id, result, hasBrowser) in group {
                if hasBrowser { browserAccounts.insert(id) } else { browserAccounts.remove(id) }
                switch result {
                case .success(let reading): publishReading(reading, for: id)
                case .failure(let error):
                    errors[id] = errorText(error)
                    if error is KeychainAccessError { credentialAccess = .locked }
                }
            }
        }
        guard credentialAccess.permitsPolling else { return }
        for provider in Provider.allCases {
            let decision = RotationPolicy.decide(provider: provider, settings: settings, readings: readings,
                                                 failures: Set(errors.keys))
            switch decision {
            case .switchTo(let id): await performSwitch(id)
            case .unavailable(let message): notify(provider, message: message)
            case .stay: break
            }
        }
    }
    func publishReading(_ reading: UsageSnapshot, for id: UUID) {
        // A response arrives after the previous UI clock tick. Update the clock
        // before publishing it so the card never treats fresh data as future data.
        now = Date()
        readings[id] = reading
        errors[id] = nil
    }

    func switchAccount(_ id: UUID) async {
        guard !busy, !previewOnly, credentialAccess.permitsPolling else { return }
        busy = true; defer { busy = false }
        await performSwitch(id)
    }
    private func performSwitch(_ id: UUID) async {
        guard let target = settings.accounts.first(where: { $0.id == id }), target.enabled,
              let originalID = settings.active[target.provider], originalID != id,
              let original = settings.accounts.first(where: { $0.id == originalID }) else { return }
        if demo {
            settings.active[target.provider] = id; lastResult = t("Demo: selected %@. Real sign-ins were not changed.", target.label); return
        }
        var reopenURL: URL?
        do {
            guard target.canSwitch else { throw AppFailure.unsupported(t("Only monitoring is connected for this service.")) }
            // Recheck both target access and quota just before affecting a client.
            let fresh = try await runtime.fetch(account: target, settings: settings)
            guard fresh.isFresh(at: Date()), !RotationPolicy.exhausted(fresh, account: target) else {
                throw AppFailure.message(t("The selected account has insufficient verified quota."))
            }
            publishReading(fresh, for: target.id)
            if target.browserEnabled { try await runtime.checkBrowserReady(target.id) }
            settings.automationPausedReason = t("Switching did not finish. Check the active account before continuing.")
            try saveOrThrow()
            if target.provider == .codex {
                guard settings.restartCodex else { throw AppFailure.message(t("Allow restarting Codex in Settings to switch accounts.")) }
                reopenURL = try await DesktopHandoff.closeCodex()
            }
            try await runtime.switchNative(to: target, from: original, settings: settings)
            settings.active[target.provider] = target.id
            settings.lastSwitch[target.provider] = Date()
            try saveOrThrow()
            try await DesktopHandoff.reopen(reopenURL)
            reopenURL = nil
            if target.browserEnabled { try await runtime.browserSwitch(account: target) }
            settings.automationPausedReason = nil
            try saveOrThrow()
            lastResult = t("%@ → %@. Credentials verified.", target.provider.name, target.label)
            if target.provider == .codex { lastResult += "\n" + t(" Codex was reopened if it was running. Task resumption is unverified.") }
            if target.browserEnabled { lastResult += "\n" + t(" Cookies applied; website account identity was not verified by the server.") }
            try store.saveReceipt(lastResult)
            notify(target.provider, message: lastResult)
        } catch {
            if error is KeychainAccessError { credentialAccess = .locked }
            if let url = reopenURL { try? await DesktopHandoff.reopen(url) }
            settings.automationPausedReason = t("Automatic switching paused after an error.")
            lastResult = errorText(error)
            try? saveOrThrow(); try? store.saveReceipt(lastResult)
            notify(target.provider, message: lastResult)
        }
    }
    func authorizeAccounts() async {
        guard !busy, !demo, !previewOnly else { return }
        busy = true
        do {
            credentialAccess = try await runtime.authorizeAccess(settings: settings)
            if credentialAccess.permitsPolling {
                settings.vaultSetupComplete = true
                try saveOrThrow()
            }
        }
        catch {
            lastResult = t("Access was not granted. Another prompt requires a new click.")
            credentialAccess = await runtime.accessStatus(settings: settings)
        }
        busy = false
        if credentialAccess.permitsPolling { await refresh() }
    }
    func closeLegacyTrackers() async {
        guard !busy, !previewOnly, !demo, credentialAccess.permitsPolling else { return }
        let activeIDs = settings.enabledProviders.compactMap { settings.active[$0] }
        guard !activeIDs.isEmpty, activeIDs.allSatisfy({ readings[$0]?.isFresh(at: Date()) == true && errors[$0] == nil }) else {
            lastResult = t("Refresh usage first: fresh data is required for all connected active accounts.")
            return
        }
        busy = true; defer { busy = false }
        do {
            let count = try await DesktopHandoff.closeLegacyTrackers()
            lastResult = t("Quit %d old trackers. SubscriptionBar remains. Their macOS login settings were not changed.", count)
        } catch { lastResult = errorText(error) }
    }
    func resume() { settings.automationPausedReason = nil; persist(); Task { await refresh() } }
    func enable(_ provider: Provider, _ enabled: Bool) {
        if enabled { settings.enabledProviders.insert(provider) } else { settings.enabledProviders.remove(provider) }
        persist()
    }
    func browser(_ id: UUID, enabled: Bool) {
        guard let index = settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        settings.accounts[index].browserEnabled = enabled; persist()
    }
    var pendingDeleteLabel: String {
        pendingDelete.flatMap { id in settings.accounts.first { $0.id == id }.map(accountLabel) } ?? ""
    }
    func balanceCurrency(_ account: Account) -> String {
        readings[account.id]?.balances.first?.currency ?? "USD"
    }
    func pathExists(_ path: String) -> Bool {
        let expanded = NSString(string: path.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
        var directory: ObjCBool = false
        return !expanded.isEmpty && FileManager.default.fileExists(atPath: expanded, isDirectory: &directory) && directory.boolValue
    }
    func setSwitchThreshold(_ value: Double) {
        settings.switchThreshold = min(max(value, 0), 50)
        if settings.warnAt < settings.switchAt { settings.warnThreshold = settings.switchAt }
        persist()
    }
    func setWarnThreshold(_ value: Double) {
        settings.warnThreshold = max(min(value, 80), settings.switchAt)
        persist()
    }
    func rename(_ id: UUID, to label: String) {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = settings.accounts.firstIndex(where: { $0.id == id }),
              !clean.isEmpty, clean.count <= 80, settings.accounts[index].label != clean else { return }
        settings.accounts[index].label = clean
        persist()
    }
    /// Removing an account must also drop its secret, or the vault keeps a
    /// credential nothing in the interface can reach.
    func delete(_ id: UUID) async {
        guard !busy, !previewOnly, let account = settings.accounts.first(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        if settings.active[account.provider] == id {
            let replacement = settings.accounts.first { $0.provider == account.provider && $0.id != id }
            if let replacement { settings.active[account.provider] = replacement.id }
            else { settings.active[account.provider] = nil }
        }
        settings.accounts.removeAll { $0.id == id }
        readings[id] = nil; errors[id] = nil; browserAccounts.remove(id)
        persist()
        guard !demo else { lastResult = t("Removed %@: %@.", account.provider.name, account.label); return }
        // A failure to clear the secret must not be reported as a clean removal.
        do {
            try await runtime.forget(id)
            lastResult = t("Removed %@: %@.", account.provider.name, account.label)
        } catch { lastResult = errorText(error) }
    }
    func move(_ id: UUID, offset: Int) {
        guard let index = settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        let candidates = settings.accounts.indices.filter { settings.accounts[$0].provider == settings.accounts[index].provider }
        guard let order = candidates.firstIndex(of: index), candidates.indices.contains(order + offset) else { return }
        settings.accounts.swapAt(index, candidates[order + offset]); persist()
    }
    private func notify(_ provider: Provider, message: String) {
        guard notifications[provider] != message else { return }
        notifications[provider] = message; lastResult = message
        let content = UNMutableNotificationContent(); content.title = provider.name; content.body = self.message(message)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: provider.rawValue, content: content, trigger: nil))
    }
    func requestNotifications() {
        guard !previewOnly else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { await self?.readNotificationStatus() }
        }
    }
    /// A permission button with no visible outcome reads as broken, so keep the
    /// current answer on screen. `UNNotificationSettings` is not Sendable, so the
    /// reply is reduced to our own value inside the callback rather than crossing
    /// the isolation boundary.
    func readNotificationStatus() async {
        guard !previewOnly else { return }
        notificationStatus = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: continuation.resume(returning: .allowed)
                case .denied: continuation.resume(returning: .denied)
                default: continuation.resume(returning: .notAsked)
                }
            }
        }
    }
    func refreshConnectionStatus() async {
        // Demo must not report the real machine's browser and notification state.
        guard !demo else { return }
        browserExtensionReady = await runtime.hasAnyBrowserSession()
        nativeHostInstalled = NativeHost.isInstalled
        await readNotificationStatus()
    }
    private func loadDemo() {
        settings.enabledProviders = [.claude, .codex, .grok, .openRouter, .deepSeek]
        for (p, used) in [(Provider.claude, 67.0), (.codex, 99), (.grok, 24), (.openRouter, 0), (.deepSeek, 0)] {
            let a = Account(provider: p, label: t("Personal"), identity: "demo-\(p.rawValue)")
            settings.accounts.append(a); settings.active[p] = a.id
            if p.usesBalance {
                readings[a.id] = try? UsageSnapshot(balances: [Balance(currency: "USD", available: p == .openRouter ? 42.75 : 8.3)], source: "Demo")
            } else {
                readings[a.id] = try? UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: used, resetsAt: Date().addingTimeInterval(7200)),
                                                            UsageWindow("Weekly", usedPercent: 32, resetsAt: Date().addingTimeInterval(172800))], source: "Demo")
            }
        }
        let spare = Account(provider: .codex, label: t("Work"), identity: "demo-spare")
        settings.accounts.append(spare)
        readings[spare.id] = try? UsageSnapshot(windows: [UsageWindow("5 hours", usedPercent: 12, resetsAt: Date().addingTimeInterval(10800))], source: "Demo")
        now = Date()
    }
}
