import SwiftUI
import WebKit

/// Toolbar buttons for enabled extensions. Clicking one opens its popup
/// (uBlock Origin Lite's per-site controls, say) for the focused pane.
struct ExtensionToolbarButtons: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let manager = ExtensionManager.shared
        HStack(spacing: 2) {
            ForEach(manager.toolbarExtensionIDs, id: \.self) { id in
                ExtensionActionButton(id: id, pane: workspace.focusedPane)
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct ExtensionActionButton: View {
    let id: String
    let pane: Pane

    var body: some View {
        let manager = ExtensionManager.shared
        // Read so the button redraws when the extension changes its icon or badge.
        let _ = manager.actionRevision
        let action = manager.action(for: id, pane: pane)
        let label = action?.label ?? manager.displayName(for: id)

        Button {
            manager.performAction(for: id, pane: pane)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = action?.icon(for: CGSize(width: 18, height: 18)) {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                    }
                }
                .frame(width: 18, height: 18)
                .padding(.horizontal, 4)

                if let badge = action?.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 8, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 11)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 2, y: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(action.map { !$0.isEnabled } ?? false)
        .help(label)
        .accessibilityLabel(label)
        .background(RegisteringArea { manager.registerActionAnchor($0, for: id) })
        .contextMenu {
            if manager.contexts[id]?.optionsPageURL != nil {
                Button("Extension Settings…") { manager.openOptions(for: id) }
            }
            SettingsLink { Text("Manage Extensions…") }
        }
    }
}
