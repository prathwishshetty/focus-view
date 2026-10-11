import AppKit
import FocusCore
import SwiftUI

/// Drawn above the panes while one is being moved: the postcard following the
/// pointer, and the highlight for docking along an edge of the window.
struct PaneDragOverlay: View {
    let size: CGSize
    @Environment(Workspace.self) private var workspace

    private var windowEdge: SplitDirection? {
        guard case .windowEdge(let edge)? = workspace.paneDrag?.target else { return nil }
        return edge
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowEdgeHighlight(edge: windowEdge, size: size, paneCount: workspace.paneCount)

            if let drag = workspace.paneDrag, let location = drag.location, let pane = workspace.pane(drag.source) {
                PanePostcard(pane: pane, snapshot: drag.snapshot)
                    // Held by the handle: the pointer sits at the card's top center.
                    .position(x: location.x, y: location.y + PanePostcard.size.height / 2 - 12)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A small, tilted card standing in for the pane being carried.
private struct PanePostcard: View {
    static let size = CGSize(width: 260, height: 180)
    private static let headerHeight: CGFloat = 26

    let pane: Pane
    let snapshot: NSImage?
    @State private var isLifted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: pane.content == .web ? "globe" : "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(pane.displayTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.headerHeight)
            .background(.bar)

            ZStack(alignment: .top) {
                Rectangle().fill(.background)
                if let snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.size.width)
                } else {
                    Image(systemName: pane.content == .web ? "globe" : "magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height - Self.headerHeight, alignment: .top)
            .clipped()
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.3), radius: 22, y: 14)
        .rotationEffect(.degrees(isLifted ? -2.5 : 0))
        .scaleEffect(isLifted ? 1 : 0.6)
        .opacity(isLifted ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { isLifted = true }
        }
    }
}

/// Shows the slot a pane will take when docked along an edge of the window.
private struct WindowEdgeHighlight: View {
    let edge: SplitDirection?
    let size: CGSize
    let paneCount: Int

    var body: some View {
        let slot = edge.map { slotRect(for: $0) } ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0)
        RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: PaneMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            )
            .overlay {
                if let edge {
                    Image(systemName: symbol(for: edge))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: slot.width, height: slot.height)
            .offset(x: slot.minX, y: slot.minY)
            .opacity(edge == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.16), value: edge)
    }

    /// Mirrors the share `SplitTree.dock` gives the docked pane.
    private func slotRect(for edge: SplitDirection) -> CGRect {
        let share = min(max(1 / CGFloat(max(paneCount, 1)), 0.25), 0.5)
        switch edge {
        case .left: return CGRect(x: 0, y: 0, width: size.width * share, height: size.height)
        case .right: return CGRect(x: size.width * (1 - share), y: 0, width: size.width * share, height: size.height)
        case .up: return CGRect(x: 0, y: 0, width: size.width, height: size.height * share)
        case .down: return CGRect(x: 0, y: size.height * (1 - share), width: size.width, height: size.height * share)
        }
    }

    private func symbol(for edge: SplitDirection) -> String {
        switch edge {
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        case .up: "rectangle.tophalf.filled"
        case .down: "rectangle.bottomhalf.filled"
        }
    }
}
