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
    let isFocused: Bool
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> WebContainerView {
        let view = WebContainerView()
        view.update(webView: pane.webView, isFocused: isFocused, cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: WebContainerView, context: Context) {
        view.update(webView: pane.webView, isFocused: isFocused, cornerRadius: cornerRadius)
    }

    static func dismantleNSView(_ view: WebContainerView, coordinator: ()) {
        view.detach()
    }
}

final class WebContainerView: NSView {
    private weak var webView: WKWebView?
    private var isFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(webView newWebView: WKWebView?, isFocused focused: Bool, cornerRadius: CGFloat) {
        layer?.cornerRadius = cornerRadius

        if let newWebView, newWebView.superview !== self {
            if let webView, webView !== newWebView, webView.superview === self {
                webView.removeFromSuperview()
            }
            newWebView.removeFromSuperview()
            newWebView.frame = bounds
            newWebView.autoresizingMask = [.width, .height]
            addSubview(newWebView)
            webView = newWebView
            // Re-parenting drops first responder; give it back to the focused pane.
            if focused { claimFirstResponder() }
        }

        if focused && !isFocused { claimFirstResponder() }
        isFocused = focused
    }

    func detach() {
        if let webView, webView.superview === self {
            webView.removeFromSuperview()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isFocused { claimFirstResponder() }
    }

    private func claimFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let webView = self.webView, webView.superview === self,
                  let window = self.window else { return }
            if window.firstResponder !== webView {
                window.makeFirstResponder(webView)
            }
        }
    }
}

/// Reports clicks that land inside its bounds without intercepting them,
/// so clicking anywhere in a pane — including inside a web page — focuses it.
struct ClickFocusMonitor: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClickMonitorView {
        let view = ClickMonitorView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickMonitorView, context: Context) {
        view.onClick = onClick
    }
}

final class ClickMonitorView: NSView {
    var onClick: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) { self.onClick?() }
            }
            return event
        }
    }
}
