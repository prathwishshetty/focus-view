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
        // No top gap: the toolbar already leaves breathing room below it.
        .padding([.horizontal, .bottom], PaneMetrics.gap)
        .background(Rectangle().fill(.background.secondary).ignoresSafeArea())
        .toolbar { toolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .navigationTitle(workspace.focusedPane.displayTitle)
        .onAppear {
            shortcuts.install(for: workspace)
            workspace.focusContent()
        }
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
