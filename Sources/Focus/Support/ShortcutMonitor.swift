import AppKit
import FocusCore

/// Routes workspace shortcuts before anything else sees them.
///
/// A web view gets first crack at key equivalents and some pages swallow them,
/// so pane shortcuts are handled by a local event monitor instead of relying
/// on menu items alone. The menus still list them for discoverability.
@MainActor
final class ShortcutMonitor {
    private var token: Any?
    private weak var workspace: Workspace?

    func install(for workspace: Workspace) {
        self.workspace = workspace
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }

    private enum Key {
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let tab: UInt16 = 48
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let workspace else { return false }
        // Leave sheets, alerts and panels alone.
        guard let window = event.window, !(window is NSPanel), window.attachedSheet == nil else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let arrow = arrowDirection(event.keyCode)

        switch modifiers {
        case [.command]:
            switch character {
            case "d": workspace.split(.right)
            case "t": workspace.newPane()
            case "w": workspace.closeFocusedPane()
            case "l": workspace.focusAddressBar()
            case "r": workspace.reload()
            case "[": workspace.goBack()
            case "]": workspace.goForward()
            case ".": workspace.stopLoading()
            case "=", "+": workspace.zoomIn()
            case "-": workspace.zoomOut()
            case "0": workspace.resetZoom()
            default: return false
            }
        case [.command, .shift]:
            if event.keyCode == Key.returnKey || event.keyCode == Key.enter {
                workspace.toggleZoom()
                return true
            }
            switch character {
            case "d": workspace.split(.down)
            case "r": workspace.reload(fromOrigin: true)
            case "+", "=": workspace.zoomIn()
            default: return false
            }
        case [.command, .option]:
            guard let arrow else { return false }
            workspace.focus(arrow)
        case [.command, .control]:
            if let arrow {
                workspace.resizeFocused(arrow)
            } else if character == "=" {
                workspace.equalize()
            } else {
                return false
            }
        case [.control]:
            guard event.keyCode == Key.tab else { return false }
            workspace.focusNext()
        case [.control, .shift]:
            guard event.keyCode == Key.tab else { return false }
            workspace.focusPrevious()
        default:
            return false
        }
        return true
    }

    private func arrowDirection(_ keyCode: UInt16) -> SplitDirection? {
        switch keyCode {
        case Key.leftArrow: .left
        case Key.rightArrow: .right
        case Key.upArrow: .up
        case Key.downArrow: .down
        default: nil
        }
    }
}
