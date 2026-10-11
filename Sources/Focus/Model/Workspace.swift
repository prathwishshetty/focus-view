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

    /// Bumped to ask the omnibox to take keyboard focus.
    private(set) var addressFocusRequest = 0

    /// The pane being dragged to a new position, if any.
    private(set) var paneDrag: PaneDrag?

    /// Views covering each pane, used to hit-test drops in window coordinates.
    @ObservationIgnored private var paneViews: [PaneID: WeakView] = [:]

    /// The size of the pane area, used to pick a split direction automatically.
    @ObservationIgnored var canvasSize = CGSize(width: 1200, height: 800)

    static let layoutAnimation = Animation.smooth(duration: 0.24)

    init() {
        let first = Pane(workspace: nil)
        tree = SplitTree(pane: first.id)
        panes = [first.id: first]
        focusedPaneID = first.id
        first.workspace = self
    }

    // MARK: - Queries

    var focusedPane: Pane {
        panes[focusedPaneID] ?? panes[tree.leaves[0]]!
    }

    var paneCount: Int { tree.count }
    var isZoomed: Bool { zoomedPaneID != nil }

    func pane(_ id: PaneID) -> Pane? { panes[id] }

    /// The window chrome blends with the focused page.
    var chromeColor: NSColor? { focusedPane.chromeColor }

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
        if let webView = pane.webView, pane.content == .web {
            // Defer until SwiftUI has (re)attached the web view to the window.
            DispatchQueue.main.async {
                guard let window = webView.window, window.firstResponder !== webView else { return }
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
        addressFocusRequest &+= 1
    }

    // MARK: - Splitting

    /// Splits a pane (the focused one by default) and shows the new tab page in the new half.
    func split(_ direction: SplitDirection, from paneID: PaneID? = nil) {
        let target = paneID.flatMap { panes[$0] != nil ? $0 : nil } ?? focusedPaneID
        insertPane(Pane(workspace: self), beside: target, direction: direction, focus: true)
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

    /// Closes a pane. Closing the last pane resets it to the new tab page.
    func close(_ id: PaneID) {
        guard let pane = panes[id] else { return }

        if tree.count == 1 {
            guard pane.content != .newTab else { return }
            let fresh = Pane(workspace: self)
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

    func beginPaneDrag(_ id: PaneID) {
        guard tree.count > 1, zoomedPaneID == nil else { return }
        paneDrag = PaneDrag(source: id)
    }

    /// Updates the drop target under `point` (window coordinates).
    func updatePaneDrag(at point: NSPoint, in window: NSWindow?) {
        guard var drag = paneDrag else { return }
        drag.target = nil
        drag.zone = nil
        for (id, box) in paneViews where id != drag.source {
            guard let view = box.view, view.window === window, window != nil,
                  !view.isHiddenOrHasHiddenAncestor else { continue }
            let local = view.convert(point, from: nil)
            guard view.bounds.contains(local) else { continue }
            drag.target = id
            drag.zone = PaneDropZone(point: local, in: view.bounds, flipped: view.isFlipped)
            break
        }
        if drag != paneDrag { paneDrag = drag }
    }

    /// Finishes a drag, moving the pane if it was dropped on another one.
    func endPaneDrag() {
        guard let drag = paneDrag else { return }
        paneDrag = nil
        guard let target = drag.target, let zone = drag.zone else { return }
        withAnimation(Self.layoutAnimation) {
            switch zone {
            case .swap: tree.swap(drag.source, target)
            case .edge(let direction): tree.move(drag.source, to: target, direction: direction)
            }
            focusedPaneID = drag.source
        }
        focusContent()
    }

    func cancelPaneDrag() {
        paneDrag = nil
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
                zoomed ? "Unzoom Pane" : "Zoom Pane",
                symbol: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            ) { [weak self] in
                self?.focus(id)
                self?.toggleZoom()
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
        withAnimation(Self.layoutAnimation) {
            if zoomedPaneID != nil {
                zoomedPaneID = nil
            } else if tree.count > 1 {
                zoomedPaneID = focusedPaneID
            }
        }
        focusContent()
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

struct PaneDrag: Equatable {
    let source: PaneID
    var target: PaneID?
    var zone: PaneDropZone?
}

final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}
