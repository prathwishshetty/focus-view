import AppKit
import FocusCore
import Observation

/// Something the command palette can do: jump to a pane, run a command, or open an address.
struct PaletteItem: Identifiable {
    enum Kind {
        case pane
        case minimizedPane
        case command
        case open
        case history

        var label: String {
            switch self {
            case .pane: "Pane"
            case .minimizedPane: "Minimized"
            case .command: "Command"
            case .open: "Open"
            case .history: "History"
            }
        }
    }

    enum Icon {
        case symbol(String)
        /// A site's favicon (or a placeholder when there's no host).
        case site(String?)
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    let icon: Icon
    var shortcut: String?
    /// Extra words the fuzzy search also looks at ("close" for "Close Pane", etc.).
    var keywords: String = ""
    /// Whether the keyboard should go back to the focused pane afterwards.
    var restoresFocus = true
    let action: @MainActor () -> Void
}

/// The ⌘K command palette's state and its list of results.
@MainActor
@Observable
final class CommandPaletteModel {
    var isVisible = false
    var query = "" {
        didSet { selectedIndex = 0 }
    }
    private(set) var selectedIndex = 0

    @ObservationIgnored weak var workspace: Workspace?
    /// Opens the Settings window; provided by the palette's view (it comes from the environment).
    @ObservationIgnored var openSettings: (() -> Void)?

    func moveSelection(by delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selectedIndex = (min(selectedIndex, count - 1) + delta + count) % count
    }

    func select(_ index: Int) {
        selectedIndex = index
    }

    func runSelected() {
        let items = items
        guard !items.isEmpty else { return }
        run(items[min(selectedIndex, items.count - 1)])
    }

    func run(_ item: PaletteItem) {
        guard let workspace else { return }
        workspace.hidePalette(restoringFocus: false)
        item.action()
        if item.restoresFocus { workspace.focusContent() }
    }

    // MARK: - Results

    var items: [PaletteItem] {
        guard let workspace else { return [] }
        let panes = paneItems(workspace)
        let commands = commandItems(workspace)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return panes + commands }

        let ranked = (panes + commands)
            .enumerated()
            .compactMap { offset, item -> (item: PaletteItem, score: Int, offset: Int)? in
                let title = FuzzyMatcher.score(query, in: item.title)
                let extra = [item.subtitle ?? "", item.keywords]
                    .compactMap { FuzzyMatcher.score(query, in: $0) }
                    .max()
                    .map { $0 / 2 }
                guard let score = [title, extra].compactMap({ $0 }).max() else { return nil }
                return (item, score, offset)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)

        let open = openItems(query, workspace: workspace)
        let history = historyItems(query, workspace: workspace)
        // An address goes first; plain words list matching panes and commands first.
        if AddressResolver.isAddress(query) {
            return open + ranked + history
        }
        return ranked + open + history
    }

    private func paneItems(_ workspace: Workspace) -> [PaletteItem] {
        var items = workspace.tree.leaves.compactMap { id -> PaletteItem? in
            guard let pane = workspace.pane(id) else { return nil }
            let isFocused = id == workspace.focusedPaneID
            return PaletteItem(
                id: "pane-\(id)",
                kind: .pane,
                title: pane.displayTitle,
                subtitle: [pane.displayHost, isFocused ? "Focused" : nil].compactMap { $0 }.joined(separator: " · "),
                icon: .site(pane.content == .web ? pane.url?.host : nil),
                keywords: "go to switch pane"
            ) {
                workspace.focus(id)
            }
        }
        items += workspace.minimizedPanes.reversed().compactMap { entry -> PaletteItem? in
            guard let pane = workspace.pane(entry.id) else { return nil }
            return PaletteItem(
                id: "minimized-\(entry.id)",
                kind: .minimizedPane,
                title: pane.displayTitle,
                subtitle: [pane.displayHost, "Minimized"].compactMap { $0 }.joined(separator: " · "),
                icon: .site(pane.content == .web ? pane.url?.host : nil),
                keywords: "restore minimized"
            ) {
                workspace.restore(entry.id)
            }
        }
        return items
    }

    private func commandItems(_ workspace: Workspace) -> [PaletteItem] {
        let pane = workspace.focusedPane
        let isWeb = pane.content == .web
        let hasSiblings = workspace.paneCount > 1

        func command(
            _ title: String,
            _ symbol: String,
            _ shortcut: String? = nil,
            keywords: String = "",
            when enabled: Bool = true,
            restoresFocus: Bool = true,
            action: @escaping @MainActor () -> Void
        ) -> PaletteItem? {
            guard enabled else { return nil }
            return PaletteItem(
                id: "command-\(title)", kind: .command, title: title, icon: .symbol(symbol),
                shortcut: shortcut, keywords: keywords, restoresFocus: restoresFocus, action: action
            )
        }

        return [
            command("New Pane", "plus.rectangle", "⌘T", keywords: "tab open") { workspace.newPane() },
            command("Split Right", "rectangle.split.2x1", "⌘D", keywords: "vertical") { workspace.split(.right) },
            command("Split Down", "rectangle.split.1x2", "⇧⌘D", keywords: "horizontal") { workspace.split(.down) },
            command("Split Left", "rectangle.split.2x1", keywords: "vertical") { workspace.split(.left) },
            command("Split Up", "rectangle.split.1x2", keywords: "horizontal") { workspace.split(.up) },
            command("Open Location", "link", "⌘L", keywords: "address url", restoresFocus: false) { workspace.focusAddressBar() },
            command("Find in Page", "magnifyingglass", "⌘F", keywords: "search text", when: isWeb, restoresFocus: false) {
                workspace.showFindBar()
            },
            command(pane.isReaderVisible ? "Hide Reader" : "Show Reader", "doc.plaintext", "⇧⌘R", keywords: "article reading",
                    when: pane.isReaderVisible || pane.isReaderAvailable) { workspace.toggleReader() },
            command("Back", "chevron.left", "⌘[", when: pane.canGoBack) { workspace.goBack() },
            command("Forward", "chevron.right", "⌘]", when: pane.canGoForward) { workspace.goForward() },
            command("Reload Page", "arrow.clockwise", "⌘R", keywords: "refresh", when: isWeb) { workspace.reload() },
            command("Reload Page From Origin", "arrow.clockwise", "⌥⌘R", keywords: "hard refresh cache", when: isWeb) {
                workspace.reload(fromOrigin: true)
            },
            command("Copy Page Link", "doc.on.doc", keywords: "url address clipboard", when: isWeb) { workspace.copyPageLink() },
            command(workspace.isZoomed ? "Restore Pane Size" : "Maximize Pane",
                    workspace.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    "⇧⌘↩", keywords: "zoom fullscreen", when: hasSiblings) { workspace.toggleZoom() },
            command("Minimize Pane", "minus", "⌃⌘M", keywords: "hide", when: hasSiblings) { workspace.minimizeFocusedPane() },
            command("Equalize Panes", "square.grid.2x2", "⌃⌘=", keywords: "balance even", when: hasSiblings) { workspace.equalize() },
            command("Focus Next Pane", "arrow.right.square", "⌃⇥", when: hasSiblings) { workspace.focusNext() },
            command("Focus Previous Pane", "arrow.left.square", "⌃⇧⇥", when: hasSiblings) { workspace.focusPrevious() },
            command("Zoom In", "plus.magnifyingglass", "⌘=", keywords: "bigger text", when: isWeb) { workspace.zoomIn() },
            command("Zoom Out", "minus.magnifyingglass", "⌘-", keywords: "smaller text", when: isWeb) { workspace.zoomOut() },
            command("Actual Size", "1.magnifyingglass", "⌘0", keywords: "reset zoom", when: isWeb) { workspace.resetZoom() },
            command("Close Pane", "xmark", "⌘W", keywords: "remove") { workspace.closeFocusedPane() },
            command("Settings", "gearshape", "⌘,", keywords: "preferences options", restoresFocus: false) { [weak self] in
                self?.openSettings?()
            },
        ].compactMap { $0 }
    }

    private func openItems(_ query: String, workspace: Workspace) -> [PaletteItem] {
        let engine = BrowserSettings.searchEngine
        guard let url = AddressResolver.resolve(query, engine: engine) else { return [] }
        let isAddress = AddressResolver.isAddress(query)
        let title = isAddress ? "Open \(query)" : "Search \(engine.displayName) for “\(query)”"
        return [
            PaletteItem(id: "open-here", kind: .open, title: title, subtitle: "In this pane",
                        icon: .symbol(isAddress ? "globe" : "magnifyingglass"), shortcut: "↩") {
                workspace.open(url, inNewPane: false)
            },
            PaletteItem(id: "open-split", kind: .open, title: title, subtitle: "In a new split",
                        icon: .symbol("rectangle.split.2x1")) {
                workspace.open(url, inNewPane: true)
            },
        ]
    }

    private func historyItems(_ query: String, workspace: Workspace) -> [PaletteItem] {
        SuggestionMatcher.matches(for: query, in: HistoryStore.shared.suggestionCandidates(), limit: 4)
            .compactMap { match -> PaletteItem? in
                guard let url = URL(string: match.candidate.url) else { return nil }
                let address = OmniboxModel.shortAddress(url)
                return PaletteItem(
                    id: "history-\(match.candidate.url)",
                    kind: .history,
                    title: match.candidate.title.isEmpty ? address : match.candidate.title,
                    subtitle: address,
                    icon: .site(url.host)
                ) {
                    workspace.open(url, inNewPane: false)
                }
            }
    }
}
