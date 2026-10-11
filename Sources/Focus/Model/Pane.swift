import AppKit
import FocusCore
import Observation
import WebKit

/// One region of the workspace. A pane starts on the new tab page and owns a
/// `WKWebView` once it navigates somewhere.
///
/// The web view lives on the pane (not on a SwiftUI view) so it survives the
/// tree being restructured when panes are split, closed or zoomed.
@MainActor
@Observable
final class Pane: Identifiable {
    enum Content: Equatable {
        case newTab
        case web
    }

    struct LoadError: Equatable {
        var title: String
        var message: String
        var url: URL?
    }

    let id: PaneID
    private(set) var content: Content = .newTab

    // Mirrored from the web view through KVO.
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isSecure = false
    private(set) var themeColor: NSColor?
    private(set) var pageBackgroundColor: NSColor?

    var loadError: LoadError?

    /// Bumped to ask the new tab page to focus its search field.
    private(set) var newTabFocusRequest = 0

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private(set) var webView: FocusWebView?
    /// The container view currently displaying `webView`. While SwiftUI animates a
    /// layout change two containers can exist for the same pane; only this one
    /// may hold the web view.
    @ObservationIgnored weak var webHost: NSView?
    @ObservationIgnored private var coordinator: PaneWebCoordinator?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Creates a pane. Pass `configuration` when WebKit asks for a new web view
    /// (`window.open`, `target=_blank`); WebKit requires that exact configuration.
    init(id: PaneID = UUID(), workspace: Workspace?, configuration: WKWebViewConfiguration? = nil) {
        self.id = id
        self.workspace = workspace
        if let configuration {
            installWebView(configuration: configuration)
        }
    }

    // MARK: - Presentation

    var displayTitle: String {
        if content == .newTab { return "New Tab" }
        if !title.isEmpty { return title }
        if let url { return AddressFormatter.displayHost(for: url) }
        return "Loading…"
    }

    /// The color the window chrome takes on so it blends with the page.
    var chromeColor: NSColor? {
        guard content == .web else { return nil }
        return themeColor ?? pageBackgroundColor
    }

    var displayHost: String? {
        guard content == .web, let url else { return nil }
        return AddressFormatter.displayHost(for: url)
    }

    // MARK: - Navigation

    /// Loads whatever the user typed: an address or a search.
    func navigate(to input: String) {
        guard let url = AddressResolver.resolve(input, engine: Preferences.searchEngine) else { return }
        load(url)
    }

    func load(_ url: URL) {
        let webView = webView ?? installWebView(configuration: nil)
        loadError = nil
        self.url = url
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func stopLoading() { webView?.stopLoading() }

    func reload(fromOrigin: Bool = false) {
        guard let webView else { return }
        loadError = nil
        if webView.url == nil, let url {
            load(url)
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    func zoomIn() { adjustZoom(by: 0.1) }
    func zoomOut() { adjustZoom(by: -0.1) }
    func resetZoom() { webView?.pageZoom = 1 }

    private func adjustZoom(by delta: CGFloat) {
        guard let webView else { return }
        webView.pageZoom = min(max(webView.pageZoom + delta, 0.3), 3)
    }

    func requestNewTabFocus() {
        newTabFocusRequest &+= 1
    }

    // MARK: - Web view lifecycle

    @discardableResult
    private func installWebView(configuration: WKWebViewConfiguration?) -> FocusWebView {
        let webView = FocusWebView(frame: .zero, configuration: configuration ?? WebViewFactory.makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true

        let coordinator = PaneWebCoordinator(pane: self)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.contextMenuExtender = { [weak self] menu in
            guard let self, let workspace = self.workspace else { return }
            workspace.appendPaneMenuItems(to: menu, for: self.id)
        }

        self.webView = webView
        self.coordinator = coordinator
        content = .web
        observe(webView)
        return webView
    }

    private func observe(_ webView: WKWebView) {
        // WebKit posts these on the main thread.
        func sync<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ apply: @escaping (Pane, Value) -> Void) -> NSKeyValueObservation {
            webView.observe(keyPath, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self, webView[keyPath: keyPath])
                }
            }
        }
        observations = [
            sync(\.title) { $0.title = $1 ?? "" },
            sync(\.url) { pane, url in if let url { pane.url = url } },
            sync(\.isLoading) { $0.isLoading = $1 },
            sync(\.estimatedProgress) { $0.progress = $1 },
            sync(\.canGoBack) { $0.canGoBack = $1 },
            sync(\.canGoForward) { $0.canGoForward = $1 },
            sync(\.hasOnlySecureContent) { $0.isSecure = $1 },
            sync(\.themeColor) { $0.themeColor = $1 },
            sync(\.underPageBackgroundColor) { $0.pageBackgroundColor = $1 },
        ]
    }

    /// Releases the web view. Called when the pane is closed.
    func tearDown() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.contextMenuExtender = nil
            webView.removeFromSuperview()
        }
        webView = nil
        coordinator = nil
    }
}

/// A web view whose right-click menu speaks in splits instead of windows.
final class FocusWebView: WKWebView {
    /// Adds pane actions (split, zoom, close…) to the page's context menu.
    var contextMenuExtender: ((NSMenu) -> Void)?

    private static let newWindowTitles: [String: String] = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": "Open Link in New Split",
        "WKMenuItemIdentifierOpenImageInNewWindow": "Open Image in New Split",
        "WKMenuItemIdentifierOpenMediaInNewWindow": "Open Video in New Split",
        "WKMenuItemIdentifierOpenFrameInNewWindow": "Open Frame in New Split",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // "New Window" items go through `createWebViewWith`, which opens a split.
        for item in menu.items {
            if let id = item.identifier?.rawValue, let title = Self.newWindowTitles[id] {
                item.title = title
            }
        }
        contextMenuExtender?(menu)
    }
}

/// Builds web view configurations shared by every pane.
@MainActor
enum WebViewFactory {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Identify as Safari so sites serve their regular desktop experience.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        return configuration
    }
}

/// User-tweakable settings. A real settings UI comes later.
enum Preferences {
    static var searchEngine: SearchEngine {
        let raw = UserDefaults.standard.string(forKey: "searchEngine") ?? ""
        return SearchEngine(rawValue: raw) ?? .google
    }
}
