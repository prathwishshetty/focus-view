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
                .overlay { OmniboxSuggestionList(canvasSize: proxy.size) }
                .overlay { CommandPalette(canvasSize: proxy.size) }
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
            // Click to go back or forward; press and hold for the pane's history.
            Menu {
                BackForwardMenuItems(pane: pane, entries: pane.backList)
            } label: {
                Label("Back", systemImage: "chevron.left")
            } primaryAction: {
                workspace.goBack()
            }
            .menuIndicator(.hidden)
            .disabled(!pane.canGoBack)
            .help("Back (⌘[) — hold for history")

            Menu {
                BackForwardMenuItems(pane: pane, entries: pane.forwardList)
            } label: {
                Label("Forward", systemImage: "chevron.right")
            } primaryAction: {
                workspace.goForward()
            }
            .menuIndicator(.hidden)
            .disabled(!pane.canGoForward)
            .help("Forward (⌘]) — hold for history")
        }

        ToolbarItem(placement: .principal) {
            Omnibox()
        }

        if !workspace.minimizedPanes.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                MinimizedShelf()
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button("Split Right", systemImage: "rectangle.split.2x1") { workspace.split(.right) }
                .help("Split right (⌘D)")
            Button("Split Down", systemImage: "rectangle.split.1x2") { workspace.split(.down) }
                .help("Split down (⇧⌘D)")
            Button(
                workspace.isZoomed ? "Restore Pane Size" : "Maximize Pane",
                systemImage: workspace.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            ) {
                workspace.toggleZoom()
            }
            .disabled(workspace.paneCount < 2)
            .help(workspace.isZoomed ? "Restore pane size (⇧⌘↩)" : "Maximize the focused pane (⇧⌘↩)")
        }
    }
}

/// A pane's back or forward list, nearest page first.
private struct BackForwardMenuItems: View {
    let pane: Pane
    let entries: [BackForwardEntry]

    var body: some View {
        ForEach(entries) { entry in
            Button(entry.title) { pane.go(to: entry.item) }
                .help(entry.url.absoluteString)
        }
    }
}

/// Minimized panes, as chips in the toolbar. Click one to put it back.
private struct MinimizedShelf: View {
    @Environment(Workspace.self) private var workspace
    private static let visibleLimit = 3

    var body: some View {
        let entries = workspace.minimizedPanes
        HStack(spacing: 4) {
            ForEach(entries.suffix(Self.visibleLimit)) { entry in
                if let pane = workspace.pane(entry.id) {
                    MinimizedChip(pane: pane)
                }
            }
            if entries.count > Self.visibleLimit {
                Menu {
                    ForEach(entries.dropLast(Self.visibleLimit)) { entry in
                        Button(workspace.pane(entry.id)?.displayTitle ?? "Pane") { workspace.restore(entry.id) }
                    }
                } label: {
                    Text("+\(entries.count - Self.visibleLimit)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More minimized panes")
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct MinimizedChip: View {
    let pane: Pane
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button {
            workspace.restore(pane.id)
        } label: {
            HStack(spacing: 5) {
                SiteIcon(host: pane.content == .web ? pane.url?.host : nil)
                    .frame(width: 14, height: 14)
                Text(pane.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Restore \(pane.displayTitle)")
        .contextMenu {
            Button("Restore", systemImage: "arrow.up.left.and.arrow.down.right") { workspace.restore(pane.id) }
            Button("Close", systemImage: "xmark") { workspace.close(pane.id) }
        }
    }
}

/// A site's favicon, falling back to a globe.
struct SiteIcon: View {
    let host: String?

    var body: some View {
        if let host, let url = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    fallback
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: host == nil ? "magnifyingglass" : "globe")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }
}
