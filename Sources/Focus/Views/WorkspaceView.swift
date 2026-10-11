import AppKit
import FocusCore
import SwiftUI

/// The window's content: the split panes plus a toolbar acting on the focused pane.
struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @State private var shortcuts = ShortcutMonitor()

    var body: some View {
        GeometryReader { proxy in
            panes
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(RegisteringArea { workspace.registerCanvasView($0) })
                .overlay { PaneDragOverlay(size: proxy.size) }
                .onAppear { workspace.canvasSize = proxy.size }
                .onChange(of: proxy.size) { _, size in workspace.canvasSize = size }
        }
        .padding(PaneMetrics.gap)
        .background(WindowBackdrop(color: chromeColor))
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarColorScheme(chromeColor.map { $0.isDark ? ColorScheme.dark : ColorScheme.light }, for: .windowToolbar)
        .navigationTitle(workspace.focusedPane.displayTitle)
        .onAppear {
            shortcuts.install(for: workspace)
            workspace.focusContent()
        }
    }

    /// The page's color reduced to a neutral gray of the same lightness, so the
    /// chrome follows the site from white to black without taking on its hue.
    private var chromeColor: NSColor? {
        workspace.chromeColor?.neutralized
    }

    @ViewBuilder
    private var panes: some View {
        if let zoomed = workspace.zoomedPaneID {
            PaneLeafView(paneID: zoomed)
                .id(zoomed)
                .transition(.scale(scale: 0.98).combined(with: .opacity))
        } else {
            SplitNodeView(node: workspace.tree.root)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let pane = workspace.focusedPane

        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { workspace.goBack() }
                .disabled(!pane.canGoBack)
                .help("Back (⌘[)")
            Button("Forward", systemImage: "chevron.right") { workspace.goForward() }
                .disabled(!pane.canGoForward)
                .help("Forward (⌘])")
        }

        ToolbarItem(placement: .principal) {
            Omnibox()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button("Split Right", systemImage: "rectangle.split.2x1") { workspace.split(.right) }
                .help("Split right (⌘D)")
            Button("Split Down", systemImage: "rectangle.split.1x2") { workspace.split(.down) }
                .help("Split down (⇧⌘D)")
            Button(
                workspace.isZoomed ? "Unzoom" : "Zoom",
                systemImage: workspace.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            ) {
                workspace.toggleZoom()
            }
            .disabled(workspace.paneCount < 2)
            .help("Zoom the focused pane (⇧⌘↩)")
        }
    }
}

/// The window's backdrop, behind the transparent toolbar and the gaps between panes.
///
/// It takes on the focused page's theme or background color, so the toolbar
/// reads as part of the website rather than a separate bar.
private struct WindowBackdrop: View {
    let color: NSColor?

    var body: some View {
        ZStack {
            Rectangle().fill(.background.secondary)
            if let color {
                Rectangle()
                    .fill(Color(nsColor: color))
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: color)
    }
}

private extension NSColor {
    /// Whether text on top of this color should be light.
    /// Perceived lightness from 0 (black) to 1 (white).
    var luminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    var isDark: Bool { luminance < 0.5 }

    /// A gray with the same lightness and opacity.
    var neutralized: NSColor {
        let alpha = usingColorSpace(.sRGB)?.alphaComponent ?? 1
        return NSColor(white: luminance, alpha: alpha)
    }
}
