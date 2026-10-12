import AppKit
import SwiftUI
import WebKit

/// Hosts a pane's long-lived `WKWebView` inside SwiftUI.
///
/// SwiftUI recreates this representable whenever the split tree changes shape;
/// the web view itself is owned by the ``Pane`` and is simply re-parented, so
/// pages never reload because of a layout change.
struct WebViewHost: NSViewRepresentable {
    let pane: Pane
    var surface: WebSurface = .page
    let isFocused: Bool
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> WebContainerView {
        let view = WebContainerView(surface: surface)
        // The newest container wins: during an animated layout change the old
        // container lingers on screen and must not take the web view back.
        pane.setHost(view, for: surface)
        view.update(pane: pane, isFocused: isFocused, cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: WebContainerView, context: Context) {
        view.update(pane: pane, isFocused: isFocused, cornerRadius: cornerRadius)
    }

    static func dismantleNSView(_ view: WebContainerView, coordinator: ()) {
        view.detach()
    }
}

final class WebContainerView: NSView {
    let surface: WebSurface
    private weak var pane: Pane?
    private var isFocused = false

    init(surface: WebSurface) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var ownsWebView: Bool {
        guard let pane else { return false }
        return pane.host(for: surface) === self
    }

    private var webView: FocusWebView? { pane?.hostedWebView(for: surface) }

    func update(pane: Pane, isFocused focused: Bool, cornerRadius: CGFloat) {
        self.pane = pane
        layer?.cornerRadius = cornerRadius

        // If the owning container was torn down, a container still on screen takes over.
        if !ownsWebView, window != nil, pane.host(for: surface) == nil {
            pane.setHost(self, for: surface)
        }

        if ownsWebView, let webView, webView.superview !== self {
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
            // Re-parenting drops first responder; give it back to the focused pane.
            if focused { claimFirstResponder() }
        }

        if focused && !isFocused { claimFirstResponder() }
        isFocused = focused
    }

    func detach() {
        guard let pane else { return }
        if let webView, webView.superview === self {
            webView.removeFromSuperview()
        }
        if pane.host(for: surface) === self {
            pane.setHost(nil, for: surface)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let pane else { return }
        update(pane: pane, isFocused: isFocused, cornerRadius: layer?.cornerRadius ?? 0)
        if isFocused { claimFirstResponder() }
    }

    private func claimFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.webView, webView.superview === self,
                  let window = self.window else { return }
            // Leave the keyboard with a field floating over the page, like its find bar.
            if window.firstResponder !== webView, !self.hasTextFieldFocusOver {
                window.makeFirstResponder(webView)
            }
        }
    }
}

/// Covers a pane: reports clicks inside it (without intercepting them), so
/// clicking anywhere — including inside a web page — focuses the pane, and
/// registers itself so pane drags can hit-test against it.
struct PaneHitArea: NSViewRepresentable {
    /// Called with the click's location in window coordinates.
    let onClick: (NSPoint) -> Void
    let register: (NSView) -> Void

    func makeNSView(context: Context) -> PaneHitView {
        let view = PaneHitView()
        view.onClick = onClick
        view.register = register
        return view
    }

    func updateNSView(_ view: PaneHitView, context: Context) {
        view.onClick = onClick
        view.register = register
    }
}

final class PaneHitView: NSView {
    var onClick: ((NSPoint) -> Void)?
    var register: ((NSView) -> Void)?
    private var monitor: Any?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        register?(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { self.onClick?(event.locationInWindow) }
            }
            return event
        }
    }
}

/// An invisible view that hands itself to `register` once it's in a window,
/// so code working in window coordinates can convert into SwiftUI's space.
struct RegisteringArea: NSViewRepresentable {
    let register: (NSView) -> Void

    func makeNSView(context: Context) -> RegisteringView {
        let view = RegisteringView()
        view.register = register
        return view
    }

    func updateNSView(_ view: RegisteringView, context: Context) {
        view.register = register
    }
}

final class RegisteringView: NSView {
    var register: ((NSView) -> Void)?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { register?(self) }
    }
}

/// Reports whether the pointer is inside it, without ever intercepting clicks.
struct TopEdgeHoverZone: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverZoneView {
        let view = HoverZoneView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: HoverZoneView, context: Context) {
        view.onHover = onHover
    }
}

final class HoverZoneView: NSView {
    var onHover: ((Bool) -> Void)?

    // Tracking areas work regardless of hit-testing, so clicks fall through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Start in the right state if the pointer is already here (deferred so
        // SwiftUI state isn't changed mid-update).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.onHover?(self.bounds.contains(point))
        }
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The mouse-tracking part of a pane's drag handle.
///
/// Implemented in AppKit so the drag keeps tracking while the pointer passes
/// over web views, which would otherwise swallow the events.
struct PaneGripArea: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onBegin: () -> Void
    var onMove: (NSPoint, NSWindow?) -> Void
    var onEnd: () -> Void

    func makeNSView(context: Context) -> PaneGripView {
        let view = PaneGripView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PaneGripView, context: Context) {
        view.onHover = onHover
        view.onBegin = onBegin
        view.onMove = onMove
        view.onEnd = onEnd
    }
}

final class PaneGripView: NSView {
    var onHover: ((Bool) -> Void)?
    var onBegin: (() -> Void)?
    var onMove: ((NSPoint, NSWindow?) -> Void)?
    var onEnd: (() -> Void)?

    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        if !isDragging, hypot(point.x - start.x, point.y - start.y) > 3 {
            isDragging = true
            NSCursor.closedHand.push()
            onBegin?()
        }
        if isDragging { onMove?(point, window) }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            NSCursor.pop()
            onMove?(event.locationInWindow, window)
            onEnd?()
        }
        isDragging = false
        mouseDownPoint = nil
    }
}

extension NSView {
    /// Whether the window's keyboard focus is in a text field drawn on top of
    /// this view (a pane's find bar sits over its page, for example).
    var hasTextFieldFocusOver: Bool {
        guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.window === window else { return false }
        let frame = convert(field.bounds, from: field)
        return bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

/// A click target that never takes keyboard focus, so clicking it leaves the
/// text field being typed in (the address bar) focused. Also reports hovering.
struct ClickArea: NSViewRepresentable {
    var onHover: (Bool) -> Void = { _ in }
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClickAreaView {
        let view = ClickAreaView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ClickAreaView, context: Context) {
        view.onHover = onHover
        view.onClick = onClick
    }
}

final class ClickAreaView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // Handled on mouse up, so the click lands like a normal button press.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
