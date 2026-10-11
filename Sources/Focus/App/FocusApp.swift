import AppKit
import SwiftUI

@main
struct FocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = Workspace()

    var body: some Scene {
        // One window, no tabs: the workspace is the whole browser.
        Window("Focus", id: "workspace") {
            WorkspaceView()
                .environment(workspace)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            FocusCommands(workspace: workspace)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Focus is single-window by design: no automatic window tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than an .app bundle.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()

        remapWindowClose()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remapWindowClose() }
        }
    }

    /// ⌘W closes the focused pane, so the window's own Close item moves to ⇧⌘W.
    private func remapWindowClose() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for item in mainMenu.items.compactMap(\.submenu).flatMap(\.items)
        where item.action == #selector(NSWindow.performClose(_:)) {
            item.title = "Close Window"
            item.keyEquivalent = "w"
            item.keyEquivalentModifierMask = [.command, .shift]
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
