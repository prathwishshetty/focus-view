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

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous)
    }

    private var dropZone: PaneDropZone? {
        guard let drag = workspace.paneDrag, drag.target == pane.id else { return nil }
        return drag.zone
    }

    private var isBeingDragged: Bool { workspace.paneDrag?.source == pane.id }

    /// The drag handle only shows while the pointer is near the top edge (or mid-drag),
    /// so it never covers the page otherwise.
    private var showsGrip: Bool { !isAlone && (isPointerNearTop || isBeingDragged) }

    var body: some View {
        ZStack(alignment: .top) {
            content

            if let error = pane.loadError {
                LoadErrorView(error: error) { pane.reload() }
                    .transition(.opacity)
            }

            LoadingBar(progress: pane.progress, isLoading: pane.isLoading, tint: accent)
        }
        .clipShape(shape)
        .overlay {
            // Unfocused splits recede slightly, like Ghostty's unfocused-split dimming.
            shape
                .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10))
                .opacity(isFocused || isAlone ? 0 : 1)
                .allowsHitTesting(false)
        }
        .overlay {
            shape
                .strokeBorder(borderStyle, lineWidth: isFocused && !isAlone ? 2 : 1)
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
                if !isAlone {
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
        .opacity(isBeingDragged ? 0.55 : 1)
        .scaleEffect(isBeingDragged ? 0.985 : 1)
        .shadow(color: .black.opacity(isFocused && !isAlone ? 0.22 : 0.10), radius: isFocused ? 10 : 4, y: 2)
        .background(
            PaneHitArea(
                onClick: { workspace.focus(pane.id) },
                register: { workspace.registerPaneView($0, for: pane.id) }
            )
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: pane.loadError)
        .animation(.easeOut(duration: 0.15), value: dropZone)
        .animation(.easeOut(duration: 0.15), value: isBeingDragged)
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .newTab:
            NewTabView(pane: pane, isFocused: isFocused)
        case .web:
            WebViewHost(pane: pane, isFocused: isFocused, cornerRadius: PaneMetrics.cornerRadius)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var accent: Color {
        if let themeColor = pane.themeColor { return Color(nsColor: themeColor) }
        return .accentColor
    }

    private var borderStyle: AnyShapeStyle {
        if isFocused && !isAlone {
            AnyShapeStyle(Color.accentColor.opacity(0.85))
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
            .opacity(isHovering || isDragging ? 1 : 0.55)
            .scaleEffect(isHovering || isDragging ? 1.08 : 1)
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
