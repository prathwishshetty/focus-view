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

    var loadError: LoadError?

    /// Bumped to ask the new tab page to focus its search field.
    private(set) var newTabFocusRequest = 0

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private(set) var webView: WKWebView?
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
    private func installWebView(configuration: WKWebViewConfiguration?) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration ?? WebViewFactory.makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true

        let coordinator = PaneWebCoordinator(pane: self)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

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
            webView.removeFromSuperview()
        }
        webView = nil
        coordinator = nil
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
