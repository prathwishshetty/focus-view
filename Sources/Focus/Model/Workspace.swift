import AppKit
import FocusCore
import Observation
import SwiftUI
import WebKit

/// The single browsing surface: a tree of panes, one of which has focus.
///
/// There are no tabs and no extra windows. New pages open as splits of the
/// focused pane, and everything — the omnibox, navigation, shortcuts — acts
/// on whichever pane has focus.
@MainActor
@Observable
final class Workspace {
    private(set) var tree: SplitTree
    private(set) var panes: [PaneID: Pane]
    private(set) var focusedPaneID: PaneID
    /// When set, only this pane is shown, filling the window.
    private(set) var zoomedPaneID: PaneID?
    /// Panes taken out of the layout but kept loaded, newest last.
    private(set) var minimizedPanes: [MinimizedPane] = []

    /// Bumped to ask the omnibox to take keyboard focus.
    private(set) var addressFocusRequest = 0

    /// The pane being dragged to a new position, if any.
    private(set) var paneDrag: PaneDrag?

    /// The address bar's text and suggestions.
    let omnibox = OmniboxModel()
    /// The ⌘K command palette.
    let palette = CommandPaletteModel()

    /// Views covering each pane, used to hit-test drops in window coordinates.
    @ObservationIgnored private var paneViews: [PaneID: WeakView] = [:]
    @ObservationIgnored private var canvasView: WeakView?
    @ObservationIgnored private var omniboxView: WeakView?
    @ObservationIgnored private var suggestionsView: WeakView?

    /// The size of the pane area, used to pick a split direction automatically.
    @ObservationIgnored var canvasSize = CGSize(width: 1200, height: 800)

    static let layoutAnimation = Animation.smooth(duration: 0.24)

    init() {
        let first = Pane(workspace: nil)
        tree = SplitTree(pane: first.id)
        panes = [first.id: first]
        focusedPaneID = first.id
        first.workspace = self
        palette.workspace = self
        if let homepage = BrowserSettings.homepageURL { first.load(homepage) }
    }

    /// A fresh pane showing the new tab page, or the homepage if the user set one.
    private func makeNewPane() -> Pane {
        let pane = Pane(workspace: self)
        if let homepage = BrowserSettings.homepageURL { pane.load(homepage) }
        return pane
    }

    /// The browser window (as opposed to Settings or a panel).
    var mainWindow: NSWindow? { canvasView?.view?.window }

    // MARK: - Queries

    var focusedPane: Pane {
        panes[focusedPaneID] ?? panes[tree.leaves[0]]!
    }

    var paneCount: Int { tree.count }
    var isZoomed: Bool { zoomedPaneID != nil }

    func pane(_ id: PaneID) -> Pane? { panes[id] }

    // MARK: - Focus

    func focus(_ id: PaneID) {
        guard panes[id] != nil else { return }
        if let zoomedPaneID, zoomedPaneID != id { self.zoomedPaneID = nil }
        guard focusedPaneID != id else { return }
        focusedPaneID = id
        focusContent()
    }

    /// Moves keyboard focus into the focused pane's content (web page or new tab field).
    func focusContent() {
        let pane = focusedPane
        if let webView = pane.displayedWebView, pane.content == .web {
            // Defer until SwiftUI has (re)attached the web view to the window.
            DispatchQueue.main.async { [weak self] in
                guard let window = webView.window, window.firstResponder !== webView else { return }
                // Don't pull the keyboard out of the pane's find bar.
                if let view = self?.paneViews[pane.id]?.view, view.hasTextFieldFocusOver { return }
                window.makeFirstResponder(webView)
            }
        } else {
            pane.requestNewTabFocus()
        }
    }

    func focus(_ direction: SplitDirection) {
        guard let target = tree.neighbor(of: focusedPaneID, direction: direction) else { return }
        focus(target)
    }

    func focusNext() {
        if let id = tree.next(after: focusedPaneID) { focus(id) }
    }

    func focusPrevious() {
        if let id = tree.previous(before: focusedPaneID) { focus(id) }
    }

    func focusAddressBar() {
        hidePalette(restoringFocus: false)
        addressFocusRequest &+= 1
    }

    // MARK: - Address bar

    /// Records the address field so its suggestions can be drawn right below it.
    func registerOmniboxView(_ view: NSView) {
        omniboxView = WeakView(view)
    }

    func registerSuggestionsView(_ view: NSView) {
        suggestionsView = WeakView(view)
    }

    /// The address field's frame in the pane area's coordinates (top-left origin).
    func omniboxFrameInCanvas() -> CGRect? {
        guard let field = omniboxView?.view, let canvas = canvasView?.view,
              let window = field.window, window === canvas.window else { return nil }
        let frame = canvas.convert(field.bounds, from: field)
        return canvas.isFlipped ? frame : CGRect(x: frame.minX, y: canvas.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Opens what the address bar holds: the highlighted suggestion, or the text as typed.
    func submitAddressBar(inNewPane: Bool = false) {
        let url = omnibox.selectedSuggestion?.url
            ?? AddressResolver.resolve(omnibox.text, engine: BrowserSettings.searchEngine)
        guard let url else { return }
        open(url, inNewPane: inNewPane)
    }

    /// Loads `url` in the focused pane, or in a new split beside it.
    func open(_ url: URL, inNewPane: Bool) {
        if inNewPane {
            open(url, inNewPaneBeside: focusedPaneID)
        } else {
            focusedPane.load(url)
            focusContent()
        }
    }

    /// Clicks on an overlay floating above the panes (the palette, the address
    /// bar's suggestions) shouldn't also focus the pane underneath.
    func shouldIgnorePaneClick(at windowPoint: NSPoint) -> Bool {
        if palette.isVisible { return true }
        if omnibox.isShowingSuggestions, let view = suggestionsView?.view, view.window != nil {
            return view.bounds.contains(view.convert(windowPoint, from: nil))
        }
        return false
    }

    // MARK: - Command palette

    func togglePalette() {
        palette.isVisible ? hidePalette() : showPalette()
    }

    func showPalette() {
        guard !palette.isVisible else { return }
        palette.query = ""
        withAnimation(.snappy(duration: 0.18)) { palette.isVisible = true }
    }

    /// Closes the palette, returning the keyboard to the focused pane unless the
    /// command that closed it puts focus somewhere itself.
    func hidePalette(restoringFocus: Bool = true) {
        guard palette.isVisible else { return }
        // Let go of the palette's field before it disappears.
        if let window = mainWindow, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            window.makeFirstResponder(nil)
        }
        withAnimation(.easeOut(duration: 0.12)) { palette.isVisible = false }
        if restoringFocus { focusContent() }
    }

    // MARK: - Find & reader

    func showFindBar() {
        let pane = focusedPane
        guard pane.content == .web else { return NSSound.beep() }
        pane.showFindBar()
    }

    func findNext() { focusedPane.findNext() }
    func findPrevious() { focusedPane.findPrevious() }

    func toggleReader() {
        let pane = focusedPane
        guard pane.isReaderVisible || pane.isReaderAvailable else { return NSSound.beep() }
        pane.toggleReader()
    }

    func copyPageLink() {
        guard focusedPane.content == .web, let url = focusedPane.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Splitting

    /// Splits a pane (the focused one by default) and shows the new tab page in the new half.
    func split(_ direction: SplitDirection, from paneID: PaneID? = nil) {
        let target = paneID.flatMap { panes[$0] != nil ? $0 : nil } ?? focusedPaneID
        insertPane(makeNewPane(), beside: target, direction: direction, focus: true)
    }

    /// Opens a new pane next to the focused one, along its longer side.
    func newPane() {
        split(automaticDirection(for: focusedPaneID))
    }

    /// Loads `url` in a new split next to `paneID` and focuses it.
    func open(_ url: URL, inNewPaneBeside paneID: PaneID) {
        openInNewPane(url, beside: paneID, focus: true)
    }

    /// Opens `url` in a new split next to `paneID` (⌘-click).
    func openInNewPane(_ url: URL, beside paneID: PaneID, focus: Bool) {
        let pane = Pane(workspace: self)
        insertPane(pane, beside: paneID, direction: automaticDirection(for: paneID), focus: focus)
        pane.load(url)
    }

    /// Creates the pane WebKit asked for via `window.open` / `target=_blank`.
    func openPopup(beside paneID: PaneID, configuration: WKWebViewConfiguration) -> Pane {
        let pane = Pane(workspace: self, configuration: configuration)
        insertPane(pane, beside: paneID, direction: automaticDirection(for: paneID), focus: true)
        return pane
    }

    private func insertPane(_ pane: Pane, beside target: PaneID, direction: SplitDirection, focus shouldFocus: Bool) {
        // A minimized pane can still open popups; those land next to the focused pane.
        let target = tree.contains(target) ? target : focusedPaneID
        withAnimation(Self.layoutAnimation) {
            zoomedPaneID = nil
            panes[pane.id] = pane
            tree.split(target, direction: direction, newPane: pane.id)
            if shouldFocus { focusedPaneID = pane.id }
        }
        if shouldFocus { focusContent() }
    }

    /// Splits along the longer side of the pane so new panes stay usable.
    private func automaticDirection(for id: PaneID) -> SplitDirection {
        guard let frame = tree.layout()[id] else { return .right }
        let width = frame.width * canvasSize.width
        let height = frame.height * canvasSize.height
        return width >= height * 1.1 ? .right : .down
    }

    // MARK: - Closing

    /// Closes the focused pane.
    func closeFocusedPane() {
        close(focusedPaneID)
    }

    /// ⌘W: closes the focused pane in the browser window, or any other window (Settings) itself.
    func performCloseCommand() {
        if let key = NSApp.keyWindow, key !== mainWindow {
            key.performClose(nil)
        } else {
            closeFocusedPane()
        }
    }

    /// Closes a pane. Closing the last pane resets it to the new tab page.
    func close(_ id: PaneID) {
        guard let pane = panes[id] else { return }

        if minimizedPanes.contains(where: { $0.id == id }) {
            withAnimation(Self.layoutAnimation) {
                minimizedPanes.removeAll { $0.id == id }
                panes[id] = nil
            }
            paneViews[id] = nil
            pane.tearDown()
            return
        }

        if tree.count == 1 {
            guard pane.content != .newTab else { return }
            let fresh = makeNewPane()
            withAnimation(Self.layoutAnimation) {
                panes[fresh.id] = fresh
                tree.replace(id, with: fresh.id)
                panes[id] = nil
                focusedPaneID = fresh.id
                zoomedPaneID = nil
            }
            pane.tearDown()
            focusContent()
            return
        }

        var nextFocus: PaneID?
        withAnimation(Self.layoutAnimation) {
            nextFocus = tree.remove(id)
            panes[id] = nil
            if zoomedPaneID == id { zoomedPaneID = nil }
            if focusedPaneID == id, let nextFocus { focusedPaneID = nextFocus }
        }
        paneViews[id] = nil
        pane.tearDown()
        if nextFocus != nil { focusContent() }
    }

    // MARK: - Rearranging

    /// Records the view that covers a pane so drags can find it.
    func registerPaneView(_ view: NSView, for id: PaneID) {
        paneViews[id] = WeakView(view)
    }

    /// Records the view covering the whole pane area (drop zones at the window edges).
    func registerCanvasView(_ view: NSView) {
        canvasView = WeakView(view)
    }

    /// Picks the pane up: it becomes a postcard that follows the pointer.
    func beginPaneDrag(_ id: PaneID) {
        guard tree.count > 1, zoomedPaneID == nil, let pane = panes[id] else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            paneDrag = PaneDrag(source: id)
        }
        pane.webView?.takeSnapshot(with: Self.snapshotConfiguration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, let image, self.paneDrag?.source == id else { return }
                self.paneDrag?.snapshot = image
            }
        }
    }

    private static var snapshotConfiguration: WKSnapshotConfiguration {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 480
        return configuration
    }

    /// Tracks the pointer (window coordinates) and works out where the pane would land.
    func updatePaneDrag(at point: NSPoint, in window: NSWindow?) {
        guard var drag = paneDrag, let window else { return }
        drag.target = nil

        if let canvas = canvasView?.view, canvas.window === window {
            let local = canvas.convert(point, from: nil)
            let location = CGPoint(x: local.x, y: canvas.isFlipped ? local.y : canvas.bounds.height - local.y)
            drag.location = location
            let edge = Self.windowEdge(at: location, in: canvas.bounds.size)
            // The handle starts near the top edge; only offer edge docking once the
            // pointer has left the edge bands, so a small nudge doesn't dock the pane.
            if edge == nil { drag.windowEdgesArmed = true }
            if drag.windowEdgesArmed { drag.target = edge.map(DropTarget.windowEdge) }
        }

        if drag.target == nil {
            for (id, box) in paneViews where id != drag.source {
                guard let view = box.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
                let local = view.convert(point, from: nil)
                guard view.bounds.contains(local) else { continue }
                drag.target = .pane(id, PaneDropZone(point: local, in: view.bounds, flipped: view.isFlipped))
                break
            }
        }

        if drag != paneDrag { paneDrag = drag }
    }

    /// Width of the band along the window's edges that docks a pane across the whole layout.
    static func windowEdgeBand(for size: CGSize) -> CGFloat {
        min(48, min(size.width, size.height) * 0.1)
    }

    private static func windowEdge(at point: CGPoint, in size: CGSize) -> SplitDirection? {
        let band = windowEdgeBand(for: size)
        let distances: [(SplitDirection, CGFloat)] = [
            (.left, point.x), (.right, size.width - point.x),
            (.up, point.y), (.down, size.height - point.y),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= band else { return nil }
        return nearest.0
    }

    /// Drops the pane where it was released; anywhere without a target puts it back.
    func endPaneDrag() {
        guard let drag = paneDrag else { return }
        withAnimation(Self.layoutAnimation) {
            paneDrag = nil
            switch drag.target {
            case .pane(let target, .swap)?:
                tree.swap(drag.source, target)
            case .pane(let target, .edge(let direction))?:
                tree.move(drag.source, to: target, direction: direction)
            case .windowEdge(let edge)?:
                tree.dock(drag.source, at: edge)
            case nil:
                break
            }
            focusedPaneID = drag.source
        }
        focusContent()
    }

    func cancelPaneDrag() {
        withAnimation(Self.layoutAnimation) { paneDrag = nil }
    }

    // MARK: - Context menu

    /// Pane actions appended to a web page's right-click menu.
    func appendPaneMenuItems(to menu: NSMenu, for id: PaneID) {
        guard panes[id] != nil else { return }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Split Right", symbol: "rectangle.split.2x1") { [weak self] in
            self?.split(.right, from: id)
        })
        menu.addItem(ClosureMenuItem("Split Down", symbol: "rectangle.split.1x2") { [weak self] in
            self?.split(.down, from: id)
        })
        if tree.count > 1 {
            let zoomed = zoomedPaneID == id
            menu.addItem(ClosureMenuItem(
                zoomed ? "Restore Pane Size" : "Maximize Pane",
                symbol: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            ) { [weak self] in
                self?.toggleZoom(id)
            })
            menu.addItem(ClosureMenuItem("Minimize Pane", symbol: "minus") { [weak self] in
                self?.minimize(id)
            })
            menu.addItem(ClosureMenuItem("Equalize Panes", symbol: "square.grid.2x2") { [weak self] in
                self?.equalize()
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Close Pane", symbol: "xmark") { [weak self] in
            self?.close(id)
        })
    }

    // MARK: - Layout

    func toggleZoom() {
        toggleZoom(focusedPaneID)
    }

    /// Maximizes a pane to fill the window, or restores the layout if it already does.
    func toggleZoom(_ id: PaneID) {
        guard tree.contains(id) else { return }
        withAnimation(Self.layoutAnimation) {
            if zoomedPaneID != nil {
                zoomedPaneID = nil
            } else if tree.count > 1 {
                zoomedPaneID = id
            }
            focusedPaneID = id
        }
        focusContent()
    }

    // MARK: - Minimizing

    /// Takes a pane out of the layout, keeping its page loaded, so it can be restored later.
    func minimize(_ id: PaneID) {
        guard tree.count > 1, tree.contains(id) else { return }
        let frames = tree.layout()
        var entry = MinimizedPane(id: id, anchor: nil, direction: .right)
        withAnimation(Self.layoutAnimation) {
            guard let neighbor = tree.remove(id) else { return }
            // Remember which pane it sat beside, and on which side, to restore it there.
            if let mine = frames[id], let theirs = frames[neighbor] {
                entry.anchor = neighbor
                entry.direction = Self.direction(from: theirs, to: mine)
            }
            minimizedPanes.append(entry)
            if zoomedPaneID == id { zoomedPaneID = nil }
            if focusedPaneID == id { focusedPaneID = neighbor }
        }
        focusContent()
    }

    func minimizeFocusedPane() {
        minimize(focusedPaneID)
    }

    /// Puts a minimized pane back where it was (or beside the focused pane) and focuses it.
    func restore(_ id: PaneID) {
        guard let index = minimizedPanes.firstIndex(where: { $0.id == id }) else { return }
        let entry = minimizedPanes[index]
        let anchor = entry.anchor.flatMap { tree.contains($0) ? $0 : nil }
        let target = anchor ?? focusedPaneID
        let direction = anchor != nil ? entry.direction : automaticDirection(for: target)
        withAnimation(Self.layoutAnimation) {
            minimizedPanes.remove(at: index)
            zoomedPaneID = nil
            tree.split(target, direction: direction, newPane: id)
            focusedPaneID = id
        }
        focusContent()
    }

    private static func direction(from anchor: CGRect, to frame: CGRect) -> SplitDirection {
        let dx = frame.midX - anchor.midX
        let dy = frame.midY - anchor.midY
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .down : .up
    }

    func equalize() {
        withAnimation(Self.layoutAnimation) { tree.equalize() }
    }

    func resizeFocused(_ direction: SplitDirection) {
        withAnimation(.snappy(duration: 0.15)) {
            _ = tree.resize(focusedPaneID, direction: direction, by: 0.05)
        }
    }

    /// Called continuously while a divider is dragged.
    func setRatio(_ ratio: Double, forSplit splitID: UUID) {
        tree.setRatio(ratio, forSplit: splitID)
    }

    // MARK: - Focused pane actions

    func navigate(to input: String) {
        focusedPane.navigate(to: input)
        focusContent()
    }

    func goBack() { focusedPane.goBack() }
    func goForward() { focusedPane.goForward() }
    func reload(fromOrigin: Bool = false) { focusedPane.reload(fromOrigin: fromOrigin) }
    func stopLoading() { focusedPane.stopLoading() }
    func zoomIn() { focusedPane.zoomIn() }
    func zoomOut() { focusedPane.zoomOut() }
    func resetZoom() { focusedPane.resetZoom() }
}

/// Where a dragged pane will land relative to the pane under the pointer.
enum PaneDropZone: Equatable {
    /// Trade places with the target.
    case swap
    /// Dock on this side of the target.
    case edge(SplitDirection)

    /// The middle of a pane swaps; anywhere else docks on the nearest edge.
    init(point: NSPoint, in bounds: NSRect, flipped: Bool) {
        let x = (point.x - bounds.minX) / max(bounds.width, 1)
        var y = (point.y - bounds.minY) / max(bounds.height, 1)
        if !flipped { y = 1 - y }
        if abs(x - 0.5) < 0.2, abs(y - 0.5) < 0.2 {
            self = .swap
            return
        }
        let distances: [(SplitDirection, CGFloat)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
        self = .edge(distances.min { $0.1 < $1.1 }!.0)
    }
}

/// A pane taken out of the layout, and where to put it back.
struct MinimizedPane: Equatable, Identifiable {
    let id: PaneID
    /// The pane it sat beside when minimized.
    var anchor: PaneID?
    /// Which side of `anchor` it was on.
    var direction: SplitDirection
}

/// Where a dragged pane will land.
enum DropTarget: Equatable {
    /// Relative to another pane.
    case pane(PaneID, PaneDropZone)
    /// Along an outer edge of the whole layout, spanning it.
    case windowEdge(SplitDirection)
}

struct PaneDrag: Equatable {
    let source: PaneID
    var target: DropTarget?
    /// Pointer position in the pane area's coordinates (top-left origin).
    var location: CGPoint?
    /// A picture of the page, shown on the postcard.
    var snapshot: NSImage?
    /// Whether docking along the window's edges is on (see `updatePaneDrag`).
    var windowEdgesArmed = false
}

final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}
