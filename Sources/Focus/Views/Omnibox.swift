import AppKit
import FocusCore
import SwiftUI

/// The one address field. It always reflects — and drives — the focused pane.
///
/// At rest it shows the page's host, centered. Clicking it (or ⌘L) switches to
/// the full, left-aligned address with everything selected, ready to replace.
struct Omnibox: View {
    @Environment(Workspace.self) private var workspace
    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        let pane = workspace.focusedPane

        HStack(spacing: 8) {
            leadingIcon(for: pane)
                .frame(width: 16)

            TextField("Search or enter address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: isEditing ? .regular : .medium))
                .multilineTextAlignment(isEditing ? .leading : .center)
                .focused($isEditing)
                .onSubmit(submit)
                .onExitCommand(perform: cancel)

            trailingButton(for: pane)
                .frame(width: 16)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 260, idealWidth: 520, maxWidth: 640, minHeight: 30)
        .onAppear(perform: showRestingText)
        .onChange(of: workspace.addressFocusRequest) { isEditing = true }
        .onChange(of: isEditing) { _, editing in
            if editing {
                text = AddressFormatter.editableString(for: workspace.focusedPane.content == .web ? workspace.focusedPane.url : nil)
                selectAll()
            } else {
                showRestingText()
            }
        }
        .onChange(of: workspace.focusedPaneID) {
            isEditing = false
            showRestingText()
        }
        .onChange(of: pane.url) {
            if !isEditing { showRestingText() }
        }
        .onChange(of: pane.content) {
            if !isEditing { showRestingText() }
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

    /// Reload/stop, or an empty slot of the same width so the resting text stays centered.
    @ViewBuilder
    private func trailingButton(for pane: Pane) -> some View {
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
        } else {
            Color.clear
        }
    }

    /// The compact form shown when not editing: just the host.
    private func showRestingText() {
        text = workspace.focusedPane.displayHost ?? ""
    }

    private func submit() {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return cancel() }
        isEditing = false
        workspace.navigate(to: input)
        showRestingText()
    }

    private func cancel() {
        isEditing = false
        showRestingText()
        workspace.focusContent()
    }

    private func selectAll() {
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}
