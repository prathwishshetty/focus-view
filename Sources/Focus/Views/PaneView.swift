import FocusCore
import SwiftUI

/// A single pane: a rounded card holding either a web page or the new tab page.
struct PaneView: View {
    let pane: Pane
    let isFocused: Bool
    /// True when this pane fills the window (only pane, or zoomed).
    let isAlone: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPointerNearTop = false
    @AppStorage(BrowserSettings.Key.dimUnfocusedPanes) private var dimUnfocusedPanes = true
    @AppStorage(BrowserSettings.Key.showFocusRing) private var showFocusRing = true

    /// Whether to draw the accent outline (only meaningful with several panes).
    private var showsFocusRing: Bool { isFocused && !isAlone && showFocusRing }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous)
    }

    private var dropZone: PaneDropZone? {
        guard case .pane(let target, let zone)? = workspace.paneDrag?.target, target == pane.id else { return nil }
        return zone
    }

    private var isBeingDragged: Bool { workspace.paneDrag?.source == pane.id }

    /// The drag handle only shows while the pointer is near the top edge (or mid-drag),
    /// so it never covers the page otherwise.
    private var showsGrip: Bool { !isAlone && (isPointerNearTop || isBeingDragged) }

    /// Minimize/maximize show on hover whenever there's more than one pane,
    /// including while this one is maximized (to restore it).
    private var hasSiblings: Bool { workspace.paneCount > 1 }
    private var showsWindowControls: Bool { hasSiblings && isPointerNearTop && workspace.paneDrag == nil }

    var body: some View {
        ZStack(alignment: .top) {
            content

            if let error = pane.loadError {
                LoadErrorView(error: error) { pane.reload() }
                    .transition(.opacity)
            }

            LoadingBar(progress: pane.progress, isLoading: pane.isLoading, tint: accent)
        }
        // A lifted pane leaves an empty slot behind while its postcard is carried around.
        .opacity(isBeingDragged ? 0.18 : 1)
        .clipShape(shape)
        .overlay {
            if isBeingDragged {
                shape
                    .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            // Unfocused splits recede slightly, like Ghostty's unfocused-split dimming.
            shape
                .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10))
                .opacity(isFocused || isAlone || !dimUnfocusedPanes ? 0 : 1)
                .allowsHitTesting(false)
        }
        .overlay {
            shape
                .strokeBorder(borderStyle, lineWidth: showsFocusRing ? 1.25 : 1)
                .opacity(isBeingDragged ? 0 : 1)
                .allowsHitTesting(false)
        }
        .overlay {
            if let dropZone {
                DropZoneHighlight(zone: dropZone)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if hasSiblings {
                    TopEdgeHoverZone { hovering in
                        withAnimation(.easeOut(duration: 0.15)) { isPointerNearTop = hovering }
                    }
                    .frame(height: 36)
                }
                if showsGrip {
                    PaneGrip(paneID: pane.id)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if pane.isFindBarVisible {
                // Below the strip where the pane's hover controls appear.
                FindBar(pane: pane)
                    .padding(.top, hasSiblings ? 34 : 10)
                    .padding(.trailing, 10)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsWindowControls {
                PaneWindowControls(paneID: pane.id, isMaximized: workspace.zoomedPaneID == pane.id)
                    .padding(.top, 5)
                    .padding(.trailing, 6)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .shadow(color: .black.opacity(isFocused && !isAlone ? 0.22 : 0.10), radius: isFocused ? 10 : 4, y: 2)
        .background(
            PaneHitArea(
                onClick: { point in
                    guard !workspace.shouldIgnorePaneClick(at: point) else { return }
                    workspace.focus(pane.id)
                },
                register: { workspace.registerPaneView($0, for: pane.id) }
            )
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: pane.loadError)
        .animation(.easeOut(duration: 0.15), value: dropZone)
        .animation(.easeOut(duration: 0.15), value: isBeingDragged)
        .animation(.easeOut(duration: 0.15), value: pane.isFindBarVisible)
        .animation(.easeInOut(duration: 0.22), value: pane.isReaderVisible)
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .newTab:
            NewTabView(pane: pane, isFocused: isFocused)
        case .web:
            ZStack {
                if pane.isReaderVisible {
                    WebViewHost(pane: pane, surface: .reader, isFocused: isFocused, cornerRadius: PaneMetrics.cornerRadius)
                        .transition(.opacity)
                } else {
                    WebViewHost(pane: pane, surface: .page, isFocused: isFocused, cornerRadius: PaneMetrics.cornerRadius)
                        .transition(.opacity)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var accent: Color {
        if let themeColor = pane.themeColor { return Color(nsColor: themeColor) }
        return .accentColor
    }

    private var borderStyle: AnyShapeStyle {
        if showsFocusRing {
            AnyShapeStyle(Color.accentColor.opacity(0.5))
        } else {
            AnyShapeStyle(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
        }
    }
}

/// A thin progress line along the top edge of a pane.
private struct LoadingBar: View {
    let progress: Double
    let isLoading: Bool
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.6), tint],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(proxy.size.width * progress, 12))
                .shadow(color: tint.opacity(0.6), radius: 3)
        }
        .frame(height: 2.5)
        .opacity(isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: progress)
        .animation(.easeOut(duration: 0.4), value: isLoading)
        .allowsHitTesting(false)
    }
}

private struct LoadErrorView: View {
    let error: Pane.LoadError
    let retry: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text(error.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if let url = error.url {
                    Text(AddressFormatter.displayHost(for: url))
                        .font(.callout.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Button("Try Again", action: retry)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding(32)
        }
    }
}

/// Find in page: a small floating bar in the pane's top corner.
private struct FindBar: View {
    @Bindable var pane: Pane
    @FocusState private var isFieldFocused: Bool

    private var status: String {
        let result = pane.findResult
        if pane.findQuery.isEmpty { return "" }
        if result.count == 0 { return "No matches" }
        return "\(result.index) of \(result.count)\(result.count >= 2000 ? "+" : "")"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            TextField("Find in page", text: $pane.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(minWidth: 70, idealWidth: 150, maxWidth: 170)
                .focused($isFieldFocused)
                .onSubmit { pane.findNext() }
                .onExitCommand { pane.hideFindBar() }
            Text(status)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 2)
            FindButton(symbol: "chevron.up", help: "Previous match (⇧⌘G)") { pane.findPrevious() }
                .disabled(pane.findResult.count == 0)
            FindButton(symbol: "chevron.down", help: "Next match (⌘G)") { pane.findNext() }
                .disabled(pane.findResult.count == 0)
            FindButton(symbol: "xmark", help: "Done (Esc)") { pane.hideFindBar() }
        }
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .onAppear(perform: focusField)
        .onChange(of: pane.findFocusRequest) { focusField() }
        .onChange(of: pane.findQuery) { pane.findQueryDidChange() }
    }

    private func focusField() {
        DispatchQueue.main.async {
            isFieldFocused = true
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private struct FindButton: View {
        let symbol: String
        let help: String
        let action: () -> Void
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 20)
                    .foregroundStyle(isHovering && isEnabled ? .primary : .secondary)
                    .background(Capsule().fill(Color.primary.opacity(isHovering && isEnabled ? 0.1 : 0)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
            .help(help)
            .accessibilityLabel(help)
        }
    }
}

/// The handle at the top of each pane. Drag it onto another pane to rearrange:
/// drop on an edge to dock there, or in the middle to swap places.
private struct PaneGrip: View {
    let paneID: PaneID
    @Environment(Workspace.self) private var workspace
    @State private var isHovering = false

    private var isDragging: Bool { workspace.paneDrag?.source == paneID }

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 14)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            // While carried, the postcard stands in for the pane, so the handle hides.
            .opacity(isDragging ? 0 : (isHovering ? 1 : 0.7))
            .scaleEffect(isHovering ? 1.08 : 1)
            .padding(.top, 5)
            .overlay(
                PaneGripArea(
                    onHover: { hovering in
                        withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
                    },
                    onBegin: {
                        workspace.focus(paneID)
                        workspace.beginPaneDrag(paneID)
                    },
                    onMove: { point, window in workspace.updatePaneDrag(at: point, in: window) },
                    onEnd: { workspace.endPaneDrag() }
                )
                .frame(width: 64, height: 26)
            )
            .help("Drag to move this pane")
            .accessibilityLabel("Move pane")
    }
}

/// Minimize and maximize buttons for a pane, revealed near its top edge.
private struct PaneWindowControls: View {
    let paneID: PaneID
    let isMaximized: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 2) {
            ControlButton(symbol: "minus", help: "Minimize pane (⌃⌘M)") {
                workspace.minimize(paneID)
            }
            ControlButton(
                symbol: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: isMaximized ? "Restore pane size (⇧⌘↩)" : "Maximize pane (⇧⌘↩)"
            ) {
                workspace.toggleZoom(paneID)
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
    }

    private struct ControlButton: View {
        let symbol: String
        let help: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 18)
                    .foregroundStyle(isHovering ? .primary : .secondary)
                    .background(
                        Capsule().fill(Color.primary.opacity(isHovering ? 0.1 : 0))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(help)
            .accessibilityLabel(help)
        }
    }
}

/// Shows where a dragged pane will land.
private struct DropZoneHighlight: View {
    let zone: PaneDropZone

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let rect = Self.rect(for: zone, in: size)
            RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius - 2, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius - 2, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
                .overlay {
                    Image(systemName: Self.symbol(for: zone))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .padding(4)
    }

    static func rect(for zone: PaneDropZone, in size: CGSize) -> CGRect {
        switch zone {
        case .swap: CGRect(origin: .zero, size: size)
        case .edge(.left): CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .edge(.right): CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .edge(.up): CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .edge(.down): CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }

    static func symbol(for zone: PaneDropZone) -> String {
        switch zone {
        case .swap: "arrow.left.arrow.right"
        case .edge(.left): "arrow.left.to.line"
        case .edge(.right): "arrow.right.to.line"
        case .edge(.up): "arrow.up.to.line"
        case .edge(.down): "arrow.down.to.line"
        }
    }
}
