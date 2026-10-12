import AppKit
import SwiftUI
import SubscriptionCore

@MainActor
final class CodexReauthenticationWindow: NSObject, NSWindowDelegate {
    private weak var controller: CodexReauthenticationController?
    private let window: NSWindow
    private var confirmedClose = false

    init(controller: CodexReauthenticationController) {
        self.controller = controller
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 370),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = L10n.ui("Sign in again")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: CodexReauthenticationWindowContent(controller: controller))
        window.center()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeConfirmed() {
        confirmedClose = true
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmedClose || controller?.requestClose() == true
    }
}

private struct CodexReauthenticationWindowContent: View {
    @ObservedObject var controller: CodexReauthenticationController
    var body: some View {
        CodexReauthenticationView(accountName: controller.accountName, profileName: controller.profileName,
            phase: controller.phase, onStart: { method, shouldSwitch in
                controller.start(method: method, switchAfterSignIn: shouldSwitch)
            }, onCancel: controller.cancel, onClose: { controller.requestClose() }, onOpen: controller.open)
    }
}
