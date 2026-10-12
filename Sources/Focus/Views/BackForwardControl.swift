import AppKit
import SwiftUI

/// Back and forward as one capsule with a divider, like Safari's.
///
/// Click to go back or forward; press and hold (or right-click) for the pane's
/// history, nearest page first.
struct BackForwardControl: View {
    let pane: Pane
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 0) {
            HistoryButton(
                symbol: "chevron.left",
                isEnabled: pane.canGoBack,
                toolTip: "Back (⌘[) — hold for history",
                action: { workspace.goBack() },
                entries: { pane.backList },
                select: { pane.go(to: $0.item) }
            )
            .frame(width: 34, height: 28)

            Divider()
                .frame(height: 16)

            HistoryButton(
                symbol: "chevron.right",
                isEnabled: pane.canGoForward,
                toolTip: "Forward (⌘]) — hold for history",
                action: { workspace.goForward() },
                entries: { pane.forwardList },
                select: { pane.go(to: $0.item) }
            )
            .frame(width: 34, height: 28)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
    }
}

/// A toolbar button that runs `action` on click and shows a history menu when held.
///
/// Written in AppKit so the hold-to-open menu behaves like Safari's: the menu
/// appears while the button is still down and you can drag straight onto a page.
private struct HistoryButton: NSViewRepresentable {
    let symbol: String
    let isEnabled: Bool
    let toolTip: String
    let action: () -> Void
    let entries: () -> [BackForwardEntry]
    let select: (BackForwardEntry) -> Void

    func makeNSView(context: Context) -> HistoryButtonView {
        let view = HistoryButtonView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: HistoryButtonView, context: Context) {
        view.symbol = symbol
        view.isEnabled = isEnabled
        view.toolTip = toolTip
        view.setAccessibilityLabel(toolTip)
        view.action = action
        view.entries = entries
        view.select = select
    }
}

final class HistoryButtonView: NSView {
    var symbol = "" { didSet { if symbol != oldValue { updateImage() } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { updateAppearance() } } }
    var action: (() -> Void)?
    var entries: (() -> [BackForwardEntry])?
    var select: ((BackForwardEntry) -> Void)?

    private let imageView = NSImageView()
    private var holdTimer: Timer?
    private var isPressed = false { didSet { updateAppearance() } }
    private var isHovering = false { didSet { updateAppearance() } }
    private var didShowMenu = false

    /// How long a press must last before it opens the history menu.
    private static let holdDelay: TimeInterval = 0.35

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateImage()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        showMenu()
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.height, bounds.width) / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateImage() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        updateAppearance()
    }

    private func updateAppearance() {
        imageView.contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor
        let fill: CGFloat = !isEnabled ? 0 : (isPressed ? 0.14 : (isHovering ? 0.07 : 0))
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fill).cgColor
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    // MARK: - Clicking and holding

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        didShowMenu = false
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMenu() }
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        defer { isPressed = false }
        guard isEnabled, !didShowMenu else { return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showMenu()
    }

    private func showMenu() {
        holdTimer = nil
        guard let entries = entries?(), !entries.isEmpty else { return }
        didShowMenu = true

        let menu = NSMenu()
        for entry in entries {
            menu.addItem(ClosureMenuItem(entry.title) { [weak self] in self?.select?(entry) })
        }
        isPressed = true
        // Synchronous: returns once the menu closes.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.height + 4 : -4), in: self)
        isPressed = false
    }
}
