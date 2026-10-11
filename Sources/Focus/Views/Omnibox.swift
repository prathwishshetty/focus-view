import AppKit
import FocusCore
import SwiftUI

/// The one address field. It always reflects — and drives — the focused pane.
struct Omnibox: View {
    @Environment(Workspace.self) private var workspace
    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        let pane = workspace.focusedPane

        HStack(spacing: 8) {
            leadingIcon(for: pane)
                .frame(width: 16)

            ZStack(alignment: .leading) {
                TextField("Search or enter address", text: $text)
                    .textFieldStyle(.plain)
                    .focused($isEditing)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                    .opacity(isEditing ? 1 : 0)

                if !isEditing {
                    idleLabel(for: pane)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isEditing = true }
                }
            }
            .font(.system(size: 13))

            if pane.content == .web, !isEditing {
                Button {
                    pane.isLoading ? pane.stopLoading() : pane.reload()
                } label: {
                    Image(systemName: pane.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(pane.isLoading ? "Stop loading (⌘.)" : "Reload (⌘R)")
            }
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 260, idealWidth: 560, maxWidth: 680, minHeight: 30)
        .onChange(of: workspace.addressFocusRequest) { isEditing = true }
        .onChange(of: isEditing) { _, editing in
            if editing {
                text = AddressFormatter.editableString(for: workspace.focusedPane.content == .web ? workspace.focusedPane.url : nil)
                selectAll()
            }
        }
        .onChange(of: workspace.focusedPaneID) {
            if isEditing { isEditing = false }
        }
    }

    @ViewBuilder
    private func leadingIcon(for pane: Pane) -> some View {
        Group {
            if isEditing || pane.content == .newTab {
                Image(systemName: "magnifyingglass")
            } else if pane.isSecure, pane.url?.scheme == "https" {
                Image(systemName: "lock.fill")
            } else {
                Image(systemName: "globe")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func idleLabel(for pane: Pane) -> some View {
        if let host = pane.displayHost {
            HStack(spacing: 6) {
                Text(host)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                if !pane.title.isEmpty, pane.title != host {
                    Text(pane.title)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        } else {
            Text("Search or enter address")
                .foregroundStyle(.tertiary)
        }
    }

    private func submit() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return cancel() }
        isEditing = false
        workspace.navigate(to: input)
    }

    private func cancel() {
        isEditing = false
        workspace.focusContent()
    }

    private func selectAll() {
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}

/// A miniature of the split layout. Click a cell to focus that pane.
struct LayoutMinimap: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let frames = workspace.tree.layout()
        let size = CGSize(width: 34, height: 22)

        ZStack(alignment: .topLeading) {
            ForEach(workspace.tree.leaves, id: \.self) { id in
                if let unit = frames[id] {
                    let rect = CGRect(
                        x: unit.minX * size.width,
                        y: unit.minY * size.height,
                        width: unit.width * size.width,
                        height: unit.height * size.height
                    ).insetBy(dx: 1, dy: 1)
                    let isFocused = id == workspace.focusedPaneID

                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.18)))
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .offset(x: rect.minX, y: rect.minY)
                        .onTapGesture { workspace.focus(id) }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .padding(.horizontal, 4)
        .animation(Workspace.layoutAnimation, value: workspace.tree)
        .animation(.easeOut(duration: 0.15), value: workspace.focusedPaneID)
        .help("\(workspace.paneCount) pane\(workspace.paneCount == 1 ? "" : "s") — click to focus")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Layout: \(workspace.paneCount) panes")
    }
}
