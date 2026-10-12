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

    // Find in page.
    private(set) var isFindBarVisible = false
    var findQuery = ""
    private(set) var findResult = FindResult()
    /// Bumped to ask the find bar to focus (and select) its field.
    private(set) var findFocusRequest = 0

    // Reader mode.
    /// Whether the page looks like an article that reader mode can show.
    private(set) var isReaderAvailable = false
    private(set) var isReaderVisible = false

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private(set) var webView: FocusWebView?
    /// The container view currently displaying `webView`. While SwiftUI animates a
    /// layout change two containers can exist for the same pane; only this one
    /// may hold the web view.
    @ObservationIgnored weak var webHost: NSView?
    @ObservationIgnored private var coordinator: PaneWebCoordinator?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var findTask: Task<Void, Never>?

    /// Shows the article in reader mode; created the first time it's needed.
    @ObservationIgnored private(set) var readerWebView: FocusWebView?
    @ObservationIgnored weak var readerHost: NSView?
    @ObservationIgnored private var readerCoordinator: ReaderCoordinator?

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
        guard let url = AddressResolver.resolve(input, engine: BrowserSettings.searchEngine) else { return }
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

    /// Pages behind this one, nearest first (for the back button's menu).
    var backList: [BackForwardEntry] {
        Self.entries(Array((webView?.backForwardList.backList ?? []).reversed()))
    }

    /// Pages ahead of this one, nearest first (for the forward button's menu).
    var forwardList: [BackForwardEntry] {
        Self.entries(webView?.backForwardList.forwardList ?? [])
    }

    func go(to item: WKBackForwardListItem) {
        webView?.go(to: item)
    }

    private static func entries(_ items: [WKBackForwardListItem]) -> [BackForwardEntry] {
        items.prefix(25).enumerated().map { offset, item in
            let title = item.title.flatMap { $0.isEmpty ? nil : $0 } ?? AddressFormatter.displayHost(for: item.url)
            return BackForwardEntry(id: offset, title: title, url: item.url, item: item)
        }
    }

    /// The web view on screen: the page, or its reader view.
    var displayedWebView: FocusWebView? {
        isReaderVisible ? readerWebView : webView
    }

    func hostedWebView(for surface: WebSurface) -> FocusWebView? {
        switch surface {
        case .page: webView
        case .reader: readerWebView
        }
    }

    func host(for surface: WebSurface) -> NSView? {
        switch surface {
        case .page: webHost
        case .reader: readerHost
        }
    }

    func setHost(_ view: NSView?, for surface: WebSurface) {
        switch surface {
        case .page: webHost = view
        case .reader: readerHost = view
        }
    }

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

    // MARK: - Zoom & shrink-to-fit

    /// The zoom the user chose with ⌘+ / ⌘-.
    @ObservationIgnored private var userZoom = CGFloat(BrowserSettings.defaultZoom)
    /// The width (CSS px) the current page needs, when it doesn't fit the pane.
    @ObservationIgnored private var requiredPageWidth: CGFloat?
    /// Pages are never shrunk below this to make them fit; past it they scroll.
    private static let minimumFitZoom: CGFloat = 0.5

    func zoomIn() { setUserZoom(userZoom + 0.1) }
    func zoomOut() { setUserZoom(userZoom - 0.1) }
    func resetZoom() { setUserZoom(1) }

    private func setUserZoom(_ zoom: CGFloat) {
        userZoom = min(max(zoom, 0.3), 3)
        applyZoom()
    }

    /// The page reported how wide it needs to be (0 means it fits).
    func pageReportedRequiredWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        requiredPageWidth = width
        applyZoom()
    }

    /// A new page started: forget the old page's width and return to the user's zoom.
    func pageDidCommit() {
        requiredPageWidth = nil
        applyZoom()
        isReaderAvailable = false
        isReaderVisible = false
        findResult = FindResult()
    }

    /// The page finished loading: remember it, and see whether reader mode applies.
    func pageDidFinishLoading() {
        if let url = webView?.url {
            HistoryStore.shared.recordVisit(url, title: title)
        }
        checkReaderAvailability()
        if isFindBarVisible, !findQuery.isEmpty { search(findQuery) }
    }

    /// Sites with a fixed minimum width overflow narrow splits. Zoom them out just
    /// enough to fit the pane, never past the user's own zoom.
    func applyZoom() {
        guard let webView else { return }
        var zoom = userZoom
        if BrowserSettings.shrinkToFit, let required = requiredPageWidth, required > 0, webView.bounds.width > 0 {
            let fit = webView.bounds.width / required
            zoom = min(userZoom, max(fit, Self.minimumFitZoom))
        }
        if abs(webView.pageZoom - zoom) > 0.005 {
            webView.pageZoom = zoom
        }
        // Reader mode lays itself out for any width, so it just follows the user's zoom.
        if let readerWebView, abs(readerWebView.pageZoom - userZoom) > 0.005 {
            readerWebView.pageZoom = userZoom
        }
    }

    // MARK: - Find in page

    func showFindBar() {
        guard content == .web else { return }
        isFindBarVisible = true
        findFocusRequest &+= 1
        if !findQuery.isEmpty { search(findQuery) }
    }

    func hideFindBar() {
        guard isFindBarVisible else { return }
        findTask?.cancel()
        isFindBarVisible = false
        findResult = FindResult()
        for webView in [webView, readerWebView].compactMap({ $0 }) {
            runFindScript("return window.__focusFind.clear();", in: webView)
        }
        if let webView = displayedWebView, let window = webView.window {
            window.makeFirstResponder(webView)
        }
    }

    /// Searches as the user types, after a short pause.
    func findQueryDidChange() {
        findTask?.cancel()
        let query = findQuery
        guard !query.isEmpty else {
            findResult = FindResult()
            if let webView = displayedWebView { runFindScript("return window.__focusFind.clear();", in: webView) }
            return
        }
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.search(query)
        }
    }

    func findNext() { stepFind(by: 1) }
    func findPrevious() { stepFind(by: -1) }

    private func stepFind(by delta: Int) {
        guard isFindBarVisible, !findQuery.isEmpty, let webView = displayedWebView else { return }
        guard findResult.count > 0 else { return search(findQuery) }
        runFindScript("return window.__focusFind.step(delta);", arguments: ["delta": delta], in: webView)
    }

    private func search(_ query: String) {
        guard let webView = displayedWebView else { return }
        runFindScript("return window.__focusFind.search(query);", arguments: ["query": query], in: webView)
    }

    private func runFindScript(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView) {
        // Runs in an isolated world, so pages can neither see nor break it.
        webView.callAsyncJavaScript(
            FindInPage.script + "\n" + body,
            arguments: arguments,
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.isFindBarVisible, webView === self.displayedWebView,
                      case .success(let value) = result, let state = value as? [String: Any] else { return }
                self.findResult = FindResult(
                    count: (state["count"] as? Int) ?? 0,
                    index: (state["index"] as? Int) ?? 0
                )
            }
        }
    }

    // MARK: - Reader mode

    func toggleReader() {
        isReaderVisible ? hideReader() : showReader()
    }

    func showReader() {
        guard let webView, content == .web, !isReaderVisible, let pageURL = webView.url else { return }
        webView.callAsyncJavaScript(ReaderMode.extractionScript, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.webView?.url == pageURL else { return }
                guard case .success(let value) = result, let article = ReaderArticle(value) else {
                    NSSound.beep()
                    return
                }
                let reader = self.readerWebView ?? self.installReaderWebView()
                reader.pageZoom = self.userZoom
                reader.loadHTMLString(ReaderMode.document(for: article, pageURL: pageURL), baseURL: pageURL)
                self.isReaderVisible = true
                if self.workspace?.focusedPaneID == self.id { self.workspace?.focusContent() }
            }
        }
    }

    func hideReader() {
        guard isReaderVisible else { return }
        isReaderVisible = false
        if workspace?.focusedPaneID == id { workspace?.focusContent() }
        if isFindBarVisible, !findQuery.isEmpty { search(findQuery) }
    }

    /// The reader view finished laying out the article.
    func readerDidFinishLoading() {
        if isFindBarVisible, !findQuery.isEmpty { search(findQuery) }
    }

    private func checkReaderAvailability() {
        guard let webView, let url = webView.url, url.scheme == "https" || url.scheme == "http" else {
            isReaderAvailable = false
            return
        }
        webView.callAsyncJavaScript(ReaderMode.availabilityScript, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.webView?.url == url, case .success(let value) = result else { return }
                self.isReaderAvailable = (value as? Bool) ?? false
            }
        }
    }

    private func installReaderWebView() -> FocusWebView {
        let reader = FocusWebView(frame: .zero, configuration: ReaderMode.makeConfiguration())
        reader.allowsMagnification = true
        reader.isInspectable = BrowserSettings.webInspector
        let coordinator = ReaderCoordinator(pane: self)
        reader.navigationDelegate = coordinator
        reader.uiDelegate = coordinator
        reader.contextMenuExtender = { [weak self] menu in
            guard let self, let workspace = self.workspace else { return }
            workspace.appendPaneMenuItems(to: menu, for: self.id)
        }
        readerWebView = reader
        readerCoordinator = coordinator
        return reader
    }

    // MARK: - Web view lifecycle

    @discardableResult
    private func installWebView(configuration: WKWebViewConfiguration?) -> FocusWebView {
        let webView = FocusWebView(frame: .zero, configuration: configuration ?? WebViewFactory.makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = BrowserSettings.webInspector

        let coordinator = PaneWebCoordinator(pane: self)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.contextMenuExtender = { [weak self] menu in
            guard let self, let workspace = self.workspace else { return }
            workspace.appendPaneMenuItems(to: menu, for: self.id)
        }
        webView.onResize = { [weak self] in self?.applyZoom() }
        webView.onRequiredWidthReport = { [weak self] width in self?.pageReportedRequiredWidth(width) }

        self.webView = webView
        self.coordinator = coordinator
        content = .web
        observe(webView)
        applyZoom()
        return webView
    }

    private func observe(_ webView: WKWebView) {
        // WebKit posts these on the main thread.
        func sync<Value>(_ keyPath: KeyPath<WKWebView, Value>, _ apply: @escaping (Pane, Value) -> Void) -> NSKeyValueObservation {
            // Key paths are immutable, so sharing one with the observer is safe even
            // though `KeyPath` isn't marked Sendable.
            nonisolated(unsafe) let keyPath = keyPath
            return webView.observe(keyPath, options: [.initial, .new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self, webView[keyPath: keyPath])
                }
            }
        }
        observations = [
            sync(\.title) { pane, title in
                pane.title = title ?? ""
                if let title, !title.isEmpty, let url = pane.webView?.url {
                    HistoryStore.shared.updateTitle(title, for: url)
                }
            },
            sync(\.url) { pane, url in
                guard let url else { return }
                pane.url = url
                // Same-document navigations (history.pushState) never "finish"; record them here.
                if !pane.isLoading { HistoryStore.shared.recordVisit(url, title: pane.title) }
            },
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
            webView.contextMenuExtender = nil
            webView.onResize = nil
            webView.onRequiredWidthReport = nil
            webView.removeFromSuperview()
        }
        webView = nil
        coordinator = nil

        findTask?.cancel()
        if let readerWebView {
            readerWebView.stopLoading()
            readerWebView.navigationDelegate = nil
            readerWebView.uiDelegate = nil
            readerWebView.contextMenuExtender = nil
            readerWebView.removeFromSuperview()
        }
        readerWebView = nil
        readerCoordinator = nil
    }
}

/// Which of a pane's web views a container shows.
enum WebSurface {
    case page
    case reader
}

/// A page in a pane's back or forward list.
struct BackForwardEntry: Identifiable {
    let id: Int
    let title: String
    let url: URL
    let item: WKBackForwardListItem
}

/// The find bar's status: `index` of `count` (1-based; 0 when nothing matches).
struct FindResult: Equatable {
    var count = 0
    var index = 0
}

/// A web view whose right-click menu speaks in splits instead of windows.
final class FocusWebView: WKWebView {
    /// Adds pane actions (split, zoom, close…) to the page's context menu.
    var contextMenuExtender: ((NSMenu) -> Void)?
    /// Called when the view's size changes (pane resized, split, window resized).
    var onResize: (() -> Void)?
    /// Called with the width (CSS px) the page needs to avoid scrolling sideways.
    var onRequiredWidthReport: ((CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.size.width
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }

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
        configuration.userContentController = sharedContentController
        return configuration
    }

    /// One controller for every pane (popups inherit their opener's), so the
    /// message handler is registered exactly once.
    private static let sharedContentController: WKUserContentController = {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: PageWidthReporter.script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.add(PageWidthReporter.shared, name: PageWidthReporter.messageName)
        return controller
    }()
}

/// Receives each page's "I need this much width" reports and hands them to its web view.
final class PageWidthReporter: NSObject, WKScriptMessageHandler {
    static let shared = PageWidthReporter()
    static let messageName = "focusPageWidth"

    /// Reports the document's width when it overflows the viewport (0 when it fits),
    /// on load, resize and layout changes, debounced.
    static let script = """
    (() => {
      let last = -1, timer = null;
      const report = () => {
        timer = null;
        const doc = document.documentElement;
        if (!doc) return;
        const width = Math.max(doc.scrollWidth, document.body ? document.body.scrollWidth : 0);
        const value = width - doc.clientWidth > 16 ? width : 0;
        if (value === last) return;
        last = value;
        window.webkit.messageHandlers.\(messageName).postMessage(value);
      };
      const schedule = () => { if (!timer) timer = setTimeout(report, 150); };
      window.addEventListener('resize', schedule);
      window.addEventListener('load', schedule);
      window.addEventListener('pageshow', () => { last = -1; schedule(); });
      if (window.ResizeObserver) new ResizeObserver(schedule).observe(document.documentElement);
      schedule();
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let webView = message.webView as? FocusWebView,
              let width = message.body as? Double else { return }
        webView.onRequiredWidthReport?(CGFloat(width))
    }
}
