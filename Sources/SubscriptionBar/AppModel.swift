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
    @Published private(set) var lastResult = ""
    @Published var now = Date()
    @Published var credentialAccess: CredentialAccess = .checking
    @Published var notificationStatus: NotificationStatus = .unknown
    @Published var browserExtensionReady = false
    @Published var nativeHostInstalled = false
    @Published var pendingDelete: UUID?
    @Published var confirmLegacyQuit = false
    @Published var codexObservations: [UUID: CodexProfileObservation] = [:]
    @Published var codexReauthentication: CodexReauthenticationController?
    @Published private(set) var pacing: [UUID: UsagePacing] = [:]
    /// Claude Code is signed into an account that is not saved here.
    @Published private(set) var unsavedClaudeLogin: String?
    private var autoAddedClaudeLogin: String?
    @Published private(set) var availableUpdate: UpdateRelease?
    @Published private(set) var installingUpdate = false
    private var lastUpdateCheck: Date?

    enum NotificationStatus: Sendable { case unknown, notAsked, allowed, denied }
    let demo: Bool
    let previewOnly: Bool
    let store: LocalStore
    let runtime: AccountRuntime
    var settingsData: Data?
    private var pollTask: Task<Void, Never>?
    private var notifications: [Provider: String] = [:]
    private let notificationSender: (UNNotificationRequest) -> Void
    private var lastResultAuthorizationGeneration: UUID?

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
            let paced = id.map { pacing[$0] != nil } == true
            let snapshot = id.flatMap { readings[$0] }
            let account = id.flatMap { active in settings.accounts.first { $0.id == active } }
            return MenuBarEntry(provider: provider, label: MenuBarSummary.label(provider),
                                value: MenuBarSummary.value(snapshot, failed: failed, paced: paced, now: now),
                                rows: MenuBarSummary.rows(snapshot, failed: failed, paced: paced, now: now),
                                level: MenuBarSummary.level(snapshot, failed: failed, paced: paced, account: account,
                                                            settings: settings, now: now),
                                delayed: id.map { readingState($0) == .delayed } == true)
        }
    }
    var menuBarText: String { menuBarEntries.map(\.text).joined(separator: " ") }
    var menuBarAccessibilitySummary: String {
        func spoken(_ value: String) -> String { value == "—" ? t("no fresh data") : t("%@ remaining", value) }
        let parts = menuBarEntries.map { (entry: MenuBarEntry) -> String in
            let rows: [String] = entry.rows.map { (row: MenuBarRow) -> String in row.spokenWindow + " " + spoken(row.value) }
            let reading: String = rows.isEmpty ? spoken(entry.value) : rows.joined(separator: ", ")
            let delay: String = entry.delayed ? ", " + t("data is delayed") : ""
            return entry.provider.name + " " + reading + delay
        }
        return (["SubscriptionBar"] + parts + (needsAttention ? [t("needs attention")] : [])).joined(separator: ", ")
    }
    /// What the interface may show for an account; automatic switching ignores
    /// pacing and still requires a reading younger than 90 seconds.
    func readingState(_ id: UUID) -> ReadingState {
        ReadingFreshness.state(readings[id], failed: !credentialAccess.permitsPolling || errors[id] != nil,
                               paced: pacing[id] != nil, now: now)
    }
    /// Severity per provider, shared by the compact row, the card and the icon.
    var providerLevels: [Provider: UsageLevel] {
        var result: [Provider: UsageLevel] = [:]
        for provider in Provider.allCases where settings.enabledProviders.contains(provider) {
            guard let id = settings.active[provider] else { continue }
            let failed = !credentialAccess.permitsPolling || errors[id] != nil
            let account = settings.accounts.first { $0.id == id }
            result[provider] = MenuBarSummary.level(readings[id], failed: failed, paced: pacing[id] != nil, account: account,
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
    init(demo: Bool, previewOnly: Bool = false, store: LocalStore = LocalStore(),
         runtime: AccountRuntime? = nil, startPolling: Bool = true,
         notificationSender: @escaping (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }) {
        self.demo = demo
        self.previewOnly = previewOnly
        self.store = store
        self.runtime = runtime ?? AccountRuntime(store: store)
        self.notificationSender = notificationSender
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
            } catch { recordOperationFailure(error); settings.automationPausedReason = t("Settings could not be loaded.") }
            if previewOnly { credentialAccess = .preview; return }
            if !startPolling { credentialAccess = settings.accounts.isEmpty ? .ready : .checking; return }
            pollTask = Task { [weak self] in
                guard let self else { return }
                if self.settings.vaultSetupComplete == true {
                    self.credentialAccess = await self.runtime.accessStatus(settings: self.settings)
                } else if self.settings.accounts.isEmpty {
                    // Nothing saved yet: there is no vault to unlock and nothing to migrate.
                    self.credentialAccess = .ready
                } else {
                    // First launch/migration never touches Keychain until the user acts.
                    self.credentialAccess = .migration(completed: 0, total: self.settings.accounts.count)
                }
                while !Task.isCancelled {
                    if self.credentialAccess.permitsPolling { await self.refresh() }
                    await self.refreshConnectionStatus()
                    await self.checkForUpdate()
                    self.now = Date()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
    }
    func setResult(_ message: String) {
        lastResult = message
        lastResultAuthorizationGeneration = nil
    }
    func dismissResult() { setResult("") }
    func recordOperationFailure(_ error: Error) {
        let event = authorizationEvent(for: error)
        lastResult = errorText(error)
        lastResultAuthorizationGeneration = event?.generation
    }
    private func recordAccountFailure(_ error: Error, for id: UUID) {
        _ = authorizationEvent(for: error)
        errors[id] = errorText(error)
    }
    private func authorizationEvent(for error: Error) -> CredentialAuthorizationEvent? {
        guard let failure = error as? KeychainAuthorizationError else { return nil }
        let event: CredentialAuthorizationEvent
        if case .authorizationRequired(let existing) = credentialAccess, existing.target == failure.target {
            event = CredentialAuthorizationEvent(error: failure, generation: existing.generation)
        } else {
            event = CredentialAuthorizationEvent(error: failure)
        }
        credentialAccess = .authorizationRequired(event)
        return event
    }
    private func clearResult(for event: CredentialAuthorizationEvent) {
        guard lastResultAuthorizationGeneration == event.generation else { return }
        lastResult = ""
        lastResultAuthorizationGeneration = nil
    }
    func persist() {
        guard !demo, !previewOnly else { return }
        do { settingsData = try store.saveSettings(settings, expected: settingsData) }
        catch { settings.automationPausedReason = t("Cannot save settings."); recordOperationFailure(error) }
    }
    func saveOrThrow() throws {
        if !demo && !previewOnly { settingsData = try store.saveSettings(settings, expected: settingsData) }
    }
    func add(provider: Provider, label: String, apiKey: String) async -> Bool {
        guard !busy, !previewOnly, credentialAccess.permitsPolling else { return false }
        busy = true; defer { busy = false }
        do {
            if demo { setResult(t("Demo: accounts are not saved.")); return true }
            let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLabel.isEmpty, cleanLabel.count <= 80 else { throw AppFailure.message(t("Enter an account name (up to 80 characters).")) }
            if provider == .codex { return try await addCodexAccount(label: cleanLabel) }
            try await addCaptured(provider: provider, label: cleanLabel, apiKey: apiKey)
            return true
        } catch { recordOperationFailure(error); return false }
    }
    /// An empty label names a new account after the captured login's email.
    private func addCaptured(provider: Provider, label: String, apiKey: String) async throws {
        let credentials = try await runtime.capture(provider: provider, settings: settings, apiKey: apiKey)
        if let existing = settings.accounts.first(where: { $0.provider == provider && $0.identity == credentials.identity }) {
            try await runtime.save(account: existing, credential: credentials)
            settings.active[provider] = existing.id
            setResult(t("Sign-in updated: %@.", existing.label))
        } else {
            let email = credentials.metadata?["emailAddress"]?.string.map { String($0.prefix(80)) }
            let account = Account(provider: provider, label: label.isEmpty ? email ?? provider.name : label,
                                  identity: credentials.identity)
            try await runtime.save(account: account, credential: credentials)
            settings.accounts.append(account)
            settings.active[provider] = account.id
            let wasOff = !settings.enabledProviders.contains(provider)
            settings.enabledProviders.insert(provider)
            var message = t("Added %@: %@.", provider.name, account.label)
            // Turning a service back on is a settings change; say so instead of doing it quietly.
            if wasOff { message += " " + t("%@ was switched back on in Settings.", provider.name) }
            setResult(message)
        }
        try saveOrThrow()
    }
    func refresh() async {
        guard !busy, !demo, !previewOnly, credentialAccess.permitsPolling else { return }
        busy = true; defer { busy = false; now = Date() }
        await synchronizeCodexProfiles()
        await detectClaudeLogin()
        guard credentialAccess.permitsPolling else { return }
        let started = Date()
        let accounts = settings.accounts.filter {
            $0.enabled && settings.enabledProviders.contains($0.provider)
                && pacing[$0.id]?.allowsFetch(at: started) != false
        }
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
                case .success(let reading):
                    publishReading(reading, for: id)
                    pacing[id] = UsagePacing.succeeded(pacing[id], now: Date())
                case .failure(AppFailure.rateLimited(_, let retryAfter)):
                    // Not an account failure: keep the last reading on screen and wait.
                    pacing[id] = UsagePacing.refused(pacing[id], retryAfter: retryAfter, now: Date())
                case .failure(let error): recordAccountFailure(error, for: id)
                }
            }
        }
        saveReadingCache()
        guard credentialAccess.permitsPolling else { return }
        for provider in Provider.allCases {
            if provider == .codex && !codexRotationReady { continue }
            let decision = RotationPolicy.decide(provider: provider, settings: settings, readings: readings,
                                                 failures: Set(errors.keys).union(provider == .codex ? codexAccountsOwnedElsewhere : []))
            switch decision {
            case .switchTo(let id): await performSwitch(id, automatic: true)
            case .unavailable(let message): notify(provider, message: message)
            case .stay: break
            }
        }
    }
    /// Follows a `claude /login` made outside the app: the signed-in account
    /// becomes active, and an unknown one is added. If adding fails, the stale
    /// selection is cleared and the card offers to connect it by hand.
    func detectClaudeLogin() async {
        guard settings.enabledProviders.contains(.claude),
              let signedIn = try? await runtime.signedInClaude(settings: settings) else {
            unsavedClaudeLogin = nil; return
        }
        // A new login is saved under its email so its limits show at once. One
        // attempt per login: a failure leaves the card's Connect hint instead
        // of repeating an error on every poll.
        if signedIn.account == nil, autoAddedClaudeLogin != signedIn.login {
            autoAddedClaudeLogin = signedIn.login
            if (try? await addCaptured(provider: .claude, label: "", apiKey: "")) != nil {
                unsavedClaudeLogin = nil
                return
            }
        }
        unsavedClaudeLogin = signedIn.account == nil ? signedIn.login : nil
        guard settings.active[.claude] != signedIn.account?.id else { return }
        settings.active[.claude] = signedIn.account?.id
        do { try saveOrThrow() } catch { recordOperationFailure(error) }
    }
    /// Once a day; a failed check stays silent and retries the next day.
    func checkForUpdate(now: Date = Date()) async {
        guard !demo, !previewOnly, settings.checkForUpdates != false, AppUpdater.installedBundle != nil,
              lastUpdateCheck.map({ now.timeIntervalSince($0) > 86_400 }) ?? true else { return }
        lastUpdateCheck = now
        guard let release = try? await AppUpdater.latest() else { return }
        availableUpdate = release.isNewer(than: AppUpdater.currentVersion) ? release : nil
    }
    func installUpdate() async {
        guard let release = availableUpdate, !installingUpdate else { return }
        installingUpdate = true; defer { installingUpdate = false }
        do { try await AppUpdater.install(release) } catch { recordOperationFailure(error) }
    }
    /// Startup loads this file, so a restart while a service is refusing
    /// requests can still show the last numbers instead of "—".
    private func saveReadingCache() {
        let url = store.root.appendingPathComponent("usage-cache.json")
        guard let data = try? JSONEncoder().encode(LiveCache(readings: readings, errors: errors)) else { return }
        try? SecureFiles.write(data, to: url, expected: SecureFiles.read(url))
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
    private func performSwitch(_ id: UUID, automatic: Bool = false) async {
        guard let target = settings.accounts.first(where: { $0.id == id }), target.enabled else { return }
        if target.provider == .codex { await performCodexSwitch(target, automatic: automatic); return }
        guard let originalID = settings.active[target.provider], originalID != id else { return }
        if demo {
            settings.active[target.provider] = id
            setResult(t("Demo: selected %@. Real sign-ins were not changed.", target.label))
            return
        }
        guard let original = settings.accounts.first(where: { $0.id == originalID }) else { return }
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
            try await runtime.switchNative(to: target, from: original, settings: settings)
            settings.active[target.provider] = target.id
            settings.lastSwitch[target.provider] = Date()
            try saveOrThrow()
            if target.browserEnabled { try await runtime.browserSwitch(account: target) }
            settings.automationPausedReason = nil
            try saveOrThrow()
            var message = t("%@ → %@. Credentials verified.", target.provider.name, target.label)
            if target.browserEnabled { message += "\n" + t(" Cookies applied; website account identity was not verified by the server.") }
            setResult(message)
            try store.saveReceipt(lastResult)
            notify(target.provider, message: lastResult)
        } catch {
            settings.automationPausedReason = t("Automatic switching paused after an error.")
            recordOperationFailure(error)
            try? saveOrThrow(); try? store.saveReceipt(lastResult)
            notify(target.provider, message: lastResult)
        }
    }
    func authorizeAccounts() async {
        guard !busy, !demo, !previewOnly else { return }
        let pending: CredentialAuthorizationEvent?
        if case .authorizationRequired(let event) = credentialAccess { pending = event }
        else { pending = nil }
        busy = true
        do {
            credentialAccess = try await runtime.authorizeAccess(settings: settings, event: pending)
            if let pending, case .authorizationRequired(let current) = credentialAccess,
               current.generation == pending.generation {
                // The same request is still pending; do not claim recovery.
            } else if let pending {
                clearResult(for: pending)
            }
            if credentialAccess.permitsPolling {
                settings.vaultSetupComplete = true
                try saveOrThrow()
            }
        } catch let resolved as CredentialRecoveryResolvedError {
            if let pending { clearResult(for: pending) }
            credentialAccess = await runtime.accessStatus(settings: settings)
            setResult(errorText(resolved.failure))
        } catch {
            if let pending {
                credentialAccess = .authorizationRequired(pending)
                lastResult = t("Access was not granted. Another prompt requires a new click.")
                lastResultAuthorizationGeneration = pending.generation
            } else {
                recordOperationFailure(error)
                credentialAccess = await runtime.accessStatus(settings: settings)
            }
        }
        busy = false
        if credentialAccess.permitsPolling { await refresh() }
    }
    func closeLegacyTrackers() async {
        guard !busy, !previewOnly, !demo, credentialAccess.permitsPolling else { return }
        let activeIDs = settings.enabledProviders.compactMap { settings.active[$0] }
        guard !activeIDs.isEmpty, activeIDs.allSatisfy({ readings[$0]?.isFresh(at: Date()) == true && errors[$0] == nil }) else {
            setResult(t("Refresh usage first: fresh data is required for all connected active accounts."))
            return
        }
        busy = true; defer { busy = false }
        do {
            let count = try await DesktopHandoff.closeLegacyTrackers()
            setResult(t("Quit %d old trackers. SubscriptionBar remains. Their macOS login settings were not changed.", count))
        } catch { recordOperationFailure(error) }
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
        let previousSettings = settings
        do {
            let forgotten = demo ? ForgottenAccountSecrets(entries: [:]) : try await runtime.forget(id)
            if settings.active[account.provider] == id {
                settings.active[account.provider] = settings.accounts.first {
                    $0.provider == account.provider && $0.id != id
                }?.id
            }
            settings.accounts.removeAll { $0.id == id }
            do { try saveOrThrow() }
            catch {
                settings = previousSettings
                if !demo { try await runtime.restore(forgotten) }
                throw error
            }
            readings[id] = nil
            errors[id] = nil
            pacing[id] = nil
            browserAccounts.remove(id)
            setResult(t("Removed %@: %@.", account.provider.name, account.label))
        } catch { recordOperationFailure(error) }
    }
    func move(_ id: UUID, offset: Int) {
        guard let index = settings.accounts.firstIndex(where: { $0.id == id }) else { return }
        let candidates = settings.accounts.indices.filter { settings.accounts[$0].provider == settings.accounts[index].provider }
        guard let order = candidates.firstIndex(of: index), candidates.indices.contains(order + offset) else { return }
        settings.accounts.swapAt(index, candidates[order + offset]); persist()
    }
    func notify(_ provider: Provider, message: String) {
        guard notifications[provider] != message else { return }
        notifications[provider] = message
        if lastResult != message { setResult(message) }
        let content = UNMutableNotificationContent(); content.title = provider.name; content.body = self.message(message)
        notificationSender(UNNotificationRequest(identifier: provider.rawValue, content: content, trigger: nil))
    }
    func requestNotifications() {
        guard !previewOnly else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable [weak self] _, _ in
            Task { await self?.readNotificationStatus() }
        }
    }
    /// A permission button with no visible outcome reads as broken, so keep the
    /// current answer on screen. `UNNotificationSettings` is not Sendable, so the
    /// reply is reduced to our own value inside the callback rather than crossing
    /// the isolation boundary. The callback runs on a background queue; without
    /// `@Sendable`, Swift 6.1 on the macOS 15 SDK infers main-actor isolation
    /// and traps at runtime when it arrives off the main thread.
    func readNotificationStatus() async {
        guard !previewOnly else { return }
        notificationStatus = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
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
