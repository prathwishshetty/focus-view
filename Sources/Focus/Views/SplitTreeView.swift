import FocusCore
import SwiftUI

enum PaneMetrics {
    /// Space between panes; doubles as the divider's grab area.
    static let gap: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    /// Panes never get smaller than this while dragging a divider.
    static let minimumLength: CGFloat = 140
}

/// Recursively renders a split tree.
struct SplitNodeView: View {
    let node: SplitNode

    var body: some View {
        switch node {
        case .leaf(let id):
            PaneLeafView(paneID: id)
                .id(id)
                .transition(.scale(scale: 0.97).combined(with: .opacity))
        case .split(let split):
            SplitContainerView(split: split)
        }
    }
}

struct PaneLeafView: View {
    let paneID: PaneID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let pane = workspace.pane(paneID) {
            PaneView(
                pane: pane,
                isFocused: workspace.focusedPaneID == paneID,
                isAlone: workspace.paneCount == 1 || workspace.isZoomed
            )
        }
    }
}

private struct SplitContainerView: View {
    let split: Split
    @Environment(Workspace.self) private var workspace

    var body: some View {
        GeometryReader { proxy in
            let isHorizontal = split.axis == .horizontal
            let total = isHorizontal ? proxy.size.width : proxy.size.height
            let available = max(total - PaneMetrics.gap, 0)
            let firstLength = (available * split.ratio).rounded()
            let secondLength = max(available - firstLength, 0)

            let layout = isHorizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))

            layout {
                SplitNodeView(node: split.first)
                    .frame(width: isHorizontal ? firstLength : nil, height: isHorizontal ? nil : firstLength)
                SplitDivider(split: split, available: available)
                SplitNodeView(node: split.second)
                    .frame(width: isHorizontal ? secondLength : nil, height: isHorizontal ? nil : secondLength)
            }
        }
    }
}

/// The gap between two panes. Drag it to resize, double-click to even out.
private struct SplitDivider: View {
    let split: Split
    let available: CGFloat

    @Environment(Workspace.self) private var workspace
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartRatio: Double?

    private var isHorizontal: Bool { split.axis == .horizontal }

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(.secondary)
                .frame(width: isHorizontal ? 3 : 36, height: isHorizontal ? 36 : 3)
                .opacity(isHovering || isDragging ? 0.6 : 0)
                .scaleEffect(isDragging ? 1.15 : 1)
        }
        .frame(width: isHorizontal ? PaneMetrics.gap : nil, height: isHorizontal ? nil : PaneMetrics.gap)
        .contentShape(Rectangle().inset(by: -3))
        .pointerStyle(isHorizontal ? .columnResize : .rowResize)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    guard available > 0 else { return }
                    let start = dragStartRatio ?? split.ratio
                    if dragStartRatio == nil {
                        dragStartRatio = start
                        isDragging = true
                    }
                    let translation = isHorizontal ? value.translation.width : value.translation.height
                    let minimum = min(PaneMetrics.minimumLength / available, 0.5)
                    let ratio = min(max(start + translation / available, minimum), 1 - minimum)
                    workspace.setRatio(ratio, forSplit: split.id)
                }
                .onEnded { _ in
                    dragStartRatio = nil
                    withAnimation(.easeOut(duration: 0.15)) { isDragging = false }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                withAnimation(Workspace.layoutAnimation) {
                    workspace.setRatio(0.5, forSplit: split.id)
                }
            }
        )
        .accessibilityLabel(isHorizontal ? "Vertical divider" : "Horizontal divider")
    }
}
