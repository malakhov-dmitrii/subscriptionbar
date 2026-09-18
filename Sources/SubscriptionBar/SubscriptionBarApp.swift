import SwiftUI
import SubscriptionCore

@main
enum Launcher {
    static var isReadOnlyPreview: Bool {
        CommandLine.arguments.contains("--preview-only") || Bundle.main.object(forInfoDictionaryKey: "SubscriptionBarPreviewOnly") as? Bool == true
    }
    @MainActor static func main() async {
        let language = (try? LocalStore().loadSettings().language) ?? AppLanguage.preferred
        L10n.language = language
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        do { try KeychainVault.disableAutomaticInteraction() }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("SubscriptionBar stopped: could not disable automatic Keychain dialogs.\n".utf8))
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "SubscriptionBarPreviewOnly") as? Bool == true { SubscriptionBarApp.main() }
        else if CommandLine.arguments.contains("--native-host") { NativeHost.run() }
        else if CommandLine.arguments.contains("--import-existing") { await ImportCommand.run(importAccounts: true) }
        else if CommandLine.arguments.contains("--fetch-live") { await ImportCommand.run(importAccounts: false) }
        else if CommandLine.arguments.contains("--repair-opencode") { await OpenCodeRepairCommand.run() }
        else if CommandLine.arguments.contains("--enable-auto-switch") { await ImportCommand.run(importAccounts: false, enableAutomation: true) }
        else { SubscriptionBarApp.main() }
    }
}

struct SubscriptionBarApp: App {
    @NSApplicationDelegateAdaptor(SubscriptionDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        let state = AppModel(demo: CommandLine.arguments.contains("--demo"), previewOnly: Launcher.isReadOnlyPreview)
        _model = StateObject(wrappedValue: state)
        SubscriptionDelegate.model = state
    }
    var body: some Scene {
        MenuBarExtra {
            DashboardView(model: model)
        } label: {
            // The icon is the only always-visible signal, so it must change shape
            // when something needs attention, not just fill level.
            Image(systemName: model.needsAttention ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
                .accessibilityLabel(model.menuBarAccessibilitySummary)
            // macOS renders the menu bar label as a template image, so colour cannot
            // carry severity here; the icon above does.
            if !model.menuBarText.isEmpty {
                Text(model.menuBarText).monospacedDigit()
            }
        }.menuBarExtraStyle(.window)
        // The Settings scene owns ⌘, ; the gear button reuses the same window
        // instead of opening a second copy of the same view.
        Settings { PreferencesView(model: model) }
    }
}

@MainActor
final class SubscriptionDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var model: AppModel?
    private static weak var current: SubscriptionDelegate?
    private static var dashboard: NSWindow?
    private static var accountWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.current = self
        if !CommandLine.arguments.contains("--background") { Self.showDashboard() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let form = Self.accountWindow, form.isVisible { form.makeKeyAndOrderFront(nil) }
        else { Self.showDashboard() }
        return true
    }
    static func showDashboard() {
        guard let model else { return }
        NSApp.setActivationPolicy(.regular)
        if dashboard == nil {
            dashboard = window(title: "SubscriptionBar", width: 430, height: 470)
            dashboard?.contentViewController = NSHostingController(rootView: DashboardView(model: model))
            // Open at the height the content needs, clamped, instead of a fixed
            // size that is too small for nine services and too tall for two.
            let fitting = dashboard?.contentViewController?.view.fittingSize.height ?? 470
            dashboard?.setContentSize(NSSize(width: 430, height: min(max(fitting, 420), 720)))
        }
        dashboard?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func updateWindowTitles() {
        accountWindow?.title = L10n.ui("Add account")
    }

    /// Route the gear button through the standard Settings scene so ⌘, and the
    /// button cannot end up showing two separate copies of the same screen.
    static func showPreferences() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        defer {
            DispatchQueue.main.async { settingsWindow = preferencesWindow ?? NSApp.keyWindow }
        }
        // Invoke the same menu item ⌘, uses; sendAction alone does not always
        // reach the Settings scene from a menu bar extra.
        if let (menu, index) = settingsMenuItem() {
            menu.performActionForItem(at: index)
            return
        }
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
    private static func settingsMenuItem() -> (NSMenu, Int)? {
        let wanted = [Selector(("showSettingsWindow:")), Selector(("showPreferencesWindow:"))]
        for item in NSApp.mainMenu?.items ?? [] {
            guard let submenu = item.submenu else { continue }
            // SwiftUI does not always expose the standard selector, so fall back to
            // the ⌘, item, which is the Settings item by macOS convention.
            if let index = submenu.items.firstIndex(where: { $0.action.map(wanted.contains) == true })
                ?? submenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command }) {
                return (submenu, index)
            }
        }
        return nil
    }
    private static weak var settingsWindow: NSWindow?
    private static var preferencesWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true }
    }
    static func showAddAccount(provider: Provider = .claude) {
        guard let model else { return }
        NSApp.setActivationPolicy(.regular)
        // A sheet hosted by MenuBarExtra is destroyed when its transient parent
        // dismisses. Own this window independently and preserve an unfinished form.
        if accountWindow == nil {
            let form = window(title: L10n.ui("Add account"), width: 470, height: 430, resizable: false)
            form.contentViewController = NSHostingController(rootView: AddAccountView(model: model, provider: provider) {
                Self.accountWindow?.close()
            })
            accountWindow = form
        }
        accountWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private static func window(title: String, width: CGFloat, height: CGFloat, resizable: Bool = true) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: mask, backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.center()
        window.delegate = Self.current
        return window
    }
    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === Self.accountWindow {
            Self.accountWindow = nil
        }
        DispatchQueue.main.async {
            if Self.dashboard?.isVisible != true && Self.settingsWindow?.isVisible != true
                && Self.accountWindow?.isVisible != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
