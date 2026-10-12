import AppKit
import WebKit

/// The workspace, as web extensions see it: one window whose tabs are the panes.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var workspace: Workspace?

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let workspace else { return [] }
        return workspace.extensionTabOrder.map { ExtensionManager.shared.tab(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let workspace else { return nil }
        return ExtensionManager.shared.tab(for: workspace.focusedPane)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = workspace?.mainWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isZoomed ? .maximized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        workspace?.mainWindow?.frame ?? .null
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        workspace?.mainWindow?.screen?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        workspace?.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        completionHandler(nil)
    }
}

/// A pane, as web extensions see it: a tab.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    private(set) weak var pane: Pane?

    init(pane: Pane) {
        self.pane = pane
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionManager.shared.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let pane, let workspace = pane.workspace else { return 0 }
        return workspace.extensionTabOrder.firstIndex { $0 === pane } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        pane?.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        guard let pane else { return nil }
        return pane.content == .newTab ? "New Tab" : pane.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        pane?.webView?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let pane, pane.isLoading, pane.url != pane.webView?.url else { return nil }
        return pane.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(pane?.isLoading ?? false)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        pane?.webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(pane?.webView?.pageZoom ?? 1)
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool {
        pane?.isReaderAvailable ?? false
    }

    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool {
        pane?.isReaderVisible ?? false
    }

    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if active { pane?.showReader() } else { pane?.hideReader() }
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let pane, let workspace = pane.workspace else { return false }
        return workspace.focusedPaneID == pane.id
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        pane?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        pane?.reload(fromOrigin: fromOrigin)
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        pane?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        pane?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let pane, let workspace = pane.workspace { workspace.activate(pane.id) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let pane, let workspace = pane.workspace { workspace.close(pane.id) }
        completionHandler(nil)
    }
}
