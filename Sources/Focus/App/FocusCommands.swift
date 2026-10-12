import FocusCore
import SwiftUI

/// Menu bar commands. Shortcuts are also handled by ``ShortcutMonitor`` so they
/// work even while a web page has keyboard focus; the menus make them discoverable.
struct FocusCommands: Commands {
    let workspace: Workspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Pane") { workspace.newPane() }
                .keyboardShortcut("t")
            Button("Open Location…") { workspace.focusAddressBar() }
                .keyboardShortcut("l")
            Button("Command Palette…") { workspace.togglePalette() }
                .keyboardShortcut("k")
            Divider()
            Button("Close Pane") { workspace.performCloseCommand() }
                .keyboardShortcut("w")
        }

        // Replaces the text-editing Find submenu, which only knows about text views.
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { workspace.showFindBar() }
                    .keyboardShortcut("f")
                Button("Find Next") { workspace.findNext() }
                    .keyboardShortcut("g")
                Button("Find Previous") { workspace.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        CommandGroup(after: .toolbar) {
            Button(workspace.focusedPane.isReaderVisible ? "Hide Reader" : "Show Reader") { workspace.toggleReader() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!workspace.focusedPane.isReaderAvailable && !workspace.focusedPane.isReaderVisible)
            Divider()
            Button("Reload Page") { workspace.reload() }
                .keyboardShortcut("r")
            Button("Reload Page From Origin") { workspace.reload(fromOrigin: true) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Stop Loading") { workspace.stopLoading() }
                .keyboardShortcut(".")
            Divider()
            Button("Zoom In") { workspace.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { workspace.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { workspace.resetZoom() }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu("History") {
            Button("Back") { workspace.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { workspace.goForward() }
                .keyboardShortcut("]")
            Divider()
            Button("Show Full History") { workspace.showHistory() }
                .keyboardShortcut("y")

            let recent = HistoryStore.shared.entries.prefix(12)
            if !recent.isEmpty {
                Divider()
                Section("Recently Visited") {
                    ForEach(Array(recent), id: \.url) { entry in
                        Button(entry.title.isEmpty ? entry.url : entry.title) {
                            if let url = URL(string: entry.url) { workspace.open(url, inNewPane: false) }
                        }
                    }
                }
            }

            Divider()
            Button("Clear History…") { HistoryStore.shared.confirmAndClear() }
                .disabled(HistoryStore.shared.entries.isEmpty)
        }

        CommandMenu("Pane") {
            Button("Split Right") { workspace.split(.right) }
                .keyboardShortcut("d")
            Button("Split Down") { workspace.split(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Split Left") { workspace.split(.left) }
            Button("Split Up") { workspace.split(.up) }

            Divider()

            Button("Focus Pane Left") { workspace.focus(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Pane Right") { workspace.focus(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Pane Above") { workspace.focus(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Pane Below") { workspace.focus(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Focus Next Pane") { workspace.focusNext() }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("Focus Previous Pane") { workspace.focusPrevious() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            Button(workspace.isZoomed ? "Restore Pane Size" : "Maximize Pane") { workspace.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Minimize Pane") { workspace.minimizeFocusedPane() }
                .keyboardShortcut("m", modifiers: [.command, .control])
                .disabled(workspace.paneCount < 2)
            Menu("Restore Minimized Pane") {
                ForEach(workspace.minimizedPanes) { entry in
                    Button(workspace.pane(entry.id)?.displayTitle ?? "Pane") { workspace.restore(entry.id) }
                }
            }
            .disabled(workspace.minimizedPanes.isEmpty)
            Button("Equalize Panes") { workspace.equalize() }
                .keyboardShortcut("=", modifiers: [.command, .control])

            Menu("Resize Pane") {
                Button("Move Divider Left") { workspace.resizeFocused(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                Button("Move Divider Right") { workspace.resizeFocused(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                Button("Move Divider Up") { workspace.resizeFocused(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                Button("Move Divider Down") { workspace.resizeFocused(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            }
        }
    }
}
