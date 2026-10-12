import AppKit
import FocusCore
import SwiftUI

/// The one address field. It always reflects — and drives — the focused pane.
///
/// At rest it shows the page's host, centered. Clicking it (or ⌘L) switches to
/// the full address with everything selected, ready to replace. As you type,
/// suggestions from history, favorites and the search engine appear below it
/// (see ``OmniboxSuggestionList``).
///
/// Editing state lives on ``OmniboxModel``; the field itself is AppKit (see
/// ``AddressField``) so it takes clicks reliably in the toolbar and refuses
/// keyboard focus while at rest.
struct Omnibox: View {
    @Environment(Workspace.self) private var workspace
    /// Bumped to put the keyboard in the field and select its text.
    @State private var focusRequest = 0

    private var isEditing: Bool { workspace.omnibox.isEditing }

    var body: some View {
        let pane = workspace.focusedPane
        @Bindable var model = workspace.omnibox

        HStack(spacing: 10) {
            // While editing the text starts right after the icon; at rest the
            // sides stay equal so the host is centered.
            leadingIcon(for: pane)
                .frame(width: OmniboxMetrics.iconWidth)
                .frame(width: isEditing ? OmniboxMetrics.iconWidth : Self.sideWidth, alignment: .leading)

            ZStack {
                AddressField(
                    text: $model.text,
                    isActive: model.isEditing,
                    focusRequest: focusRequest,
                    onActivate: beginEditing,
                    onSubmit: submit,
                    onCancel: cancel,
                    onFocusLost: { if workspace.omnibox.isEditing { endEditing() } }
                )

                if !model.isEditing {
                    restingLabel(for: pane)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)

            if !isEditing {
                trailingButtons(for: pane)
                    .frame(width: Self.sideWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, OmniboxMetrics.inset)
        .frame(minWidth: 260, idealWidth: 520, maxWidth: 640)
        .frame(height: OmniboxMetrics.height)
        .background {
            // With suggestions showing, the field's bottom edge opens into the list.
            OmniboxSurface(
                topRadius: OmniboxMetrics.radius,
                bottomRadius: model.isShowingSuggestions ? 0 : OmniboxMetrics.radius,
                openEdge: model.isShowingSuggestions ? .bottom : nil
            )
        }
        .background(RegisteringArea { workspace.registerOmniboxView($0) })
        .onChange(of: workspace.addressFocusRequest) { beginEditing() }
        .onChange(of: model.text) {
            model.textDidChange()
        }
        .onAppear {
            // At launch the first pane is empty: start in the address bar.
            if workspace.focusedPane.content == .newTab { beginEditing() }
        }
    }

    /// Fills in the focused pane's address and puts the keyboard in the field.
    /// Calling it again (⌘L twice) refreshes the address and reselects it.
    private func beginEditing() {
        let pane = workspace.focusedPane
        workspace.omnibox.beginEditing(with: AddressFormatter.editableString(for: pane.content == .web ? pane.url : nil))
        focusRequest &+= 1
    }

    private func endEditing() {
        workspace.omnibox.endEditing()
    }

    /// Room on each side of the field, kept equal so the resting host stays centered.
    private static let sideWidth: CGFloat = 38

    @ViewBuilder
    private func leadingIcon(for pane: Pane) -> some View {
        Group {
            if isEditing || pane.content == .newTab {
                Image(systemName: "magnifyingglass")
            } else if FocusPages.isHistory(pane.url) {
                Image(systemName: "clock.arrow.circlepath")
            } else if pane.isSecure, pane.url?.scheme == "https" {
                Image(systemName: "lock.fill")
            } else {
                Image(systemName: "globe")
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    /// The centered text shown when not editing: the site's host, or the prompt.
    @ViewBuilder
    private func restingLabel(for pane: Pane) -> some View {
        if let host = pane.displayHost {
            Text(host)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Search or enter address")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }

    /// Reader mode (when the page is an article) and reload/stop.
    @ViewBuilder
    private func trailingButtons(for pane: Pane) -> some View {
        if pane.content == .web, !isEditing {
            HStack(spacing: 6) {
                if pane.isReaderAvailable || pane.isReaderVisible {
                    Button {
                        workspace.toggleReader()
                    } label: {
                        Image(systemName: pane.isReaderVisible ? "doc.plaintext.fill" : "doc.plaintext")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(pane.isReaderVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(pane.isReaderVisible ? "Hide Reader (⇧⌘R)" : "Show Reader (⇧⌘R)")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
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
            .animation(.easeOut(duration: 0.15), value: pane.isReaderAvailable)
        } else {
            Color.clear
        }
    }

    private func submit() {
        let model = workspace.omnibox
        guard !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return cancel() }
        workspace.submitAddressBar()
        endEditing()
    }

    private func cancel() {
        endEditing()
        // An empty pane would send the cursor straight back here; leave it at rest.
        if workspace.focusedPane.content == .web { workspace.focusContent() }
    }

}

/// The address bar's text field, in AppKit.
///
/// - At rest it refuses keyboard focus, so the window never parks a caret in it;
///   a click at rest asks to begin editing instead (`onActivate`).
/// - It owns its focus: each new `focusRequest` makes it first responder and
///   selects everything, retrying briefly until the toolbar is on screen.
/// - Focus it gives up on its own (a click on a page) is reported through
///   `onFocusLost`; focus taken away because editing ended is not.
struct AddressField: NSViewRepresentable {
    @Binding var text: String
    let isActive: Bool
    let focusRequest: Int
    let onActivate: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFocusLost: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AddressTextField {
        let field = AddressTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Don't act on a request that was made before this field existed.
        context.coordinator.focusRequest = focusRequest
        return field
    }

    func updateNSView(_ field: AddressTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.onActivate = onActivate
        field.isActivated = isActive
        field.placeholderString = isActive ? "Search or enter address" : nil
        if field.stringValue != text {
            field.stringValue = text
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            coordinator.focus(field, attempts: 8)
        }
        if !isActive, field.currentEditor() != nil {
            DispatchQueue.main.async { coordinator.resign(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField?
        var focusRequest = 0
        /// Set while editing is being ended on purpose, so it isn't reported as lost focus.
        private var isResigning = false

        func focus(_ field: AddressTextField, attempts: Int) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.isActivated else { return }
                guard let window = field.window, window.isVisible else {
                    if attempts > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            self.focus(field, attempts: attempts - 1)
                        }
                    }
                    return
                }
                if field.currentEditor() == nil {
                    window.makeFirstResponder(field)
                }
                field.currentEditor()?.selectAll(nil)
            }
        }

        func resign(_ field: AddressTextField) {
            guard !field.isActivated, let editor = field.currentEditor(),
                  let window = field.window, window.firstResponder === editor else { return }
            isResigning = true
            window.makeFirstResponder(nil)
            isResigning = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent?.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !isResigning else { return }
            parent?.onFocusLost()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent?.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent?.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

final class AddressTextField: NSTextField {
    /// Whether editing has begun; at rest the field can't take keyboard focus.
    var isActivated = false
    var onActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { isActivated }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isActivated {
            super.mouseDown(with: event)
        } else {
            onActivate?()
        }
    }
}

/// Suggestions under the address bar, drawn over the panes.
struct OmniboxSuggestionList: View {
    /// The size of the pane area this list floats over.
    let canvasSize: CGSize
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let model = workspace.omnibox
        if model.isShowingSuggestions {
            // Hang from the field: same width, flush with its bottom edge, so the
            // two read as one surface. The field sits in the toolbar, above the
            // pane area, so its bottom is usually at a negative y here.
            let anchor = workspace.omniboxFrameInCanvas()
            let width = anchor?.width ?? min(520, canvasSize.width - 16)
            let x = anchor?.minX ?? (canvasSize.width - width) / 2
            let top = anchor?.maxY ?? 6
            // Start the rows below the toolbar, which would otherwise take their clicks.
            let rowsInset = max(OmniboxMetrics.listPadding, -top)

            VStack(spacing: 2) {
                ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionRow(suggestion: suggestion, isSelected: index == model.selectedIndex)
                        .overlay(
                            ClickArea(
                                onHover: { hovering in if hovering { model.select(index) } },
                                onClick: {
                                    model.select(index)
                                    workspace.submitAddressBar()
                                    model.endEditing()
                                }
                            )
                        )
                }
            }
            .padding(OmniboxMetrics.listPadding)
            .padding(.top, rowsInset - OmniboxMetrics.listPadding)
            .frame(width: width)
            .background {
                OmniboxSurface(topRadius: 0, bottomRadius: OmniboxMetrics.listRadius, openEdge: .top)
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
            }
            .overlay(alignment: .top) {
                // A faint seam between what you typed and the suggestions.
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, OmniboxMetrics.inset)
            }
            .background(RegisteringArea { workspace.registerSuggestionsView($0) })
            // Real layout (not an offset), so the click areas' AppKit views land in the right place.
            .padding(.leading, x)
            .padding(.top, top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: OmniboxSuggestion
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                    .font(.system(size: 13, weight: suggestion.kind == .topHit ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let tag {
                Text(tag)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(height: suggestion.detail == nil ? 28 : 38)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        switch suggestion.kind {
        case .topHit, .history, .favorite:
            SiteIcon(host: suggestion.url.host)
        case .search:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        case .address:
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        }
    }

    private var tag: String? {
        switch suggestion.kind {
        case .topHit: "Top Hit"
        case .favorite: "Favorite"
        case .history, .search, .address: nil
        }
    }
}

/// Sizes shared by the address field and the suggestion list hanging from it,
/// chosen so the field's icon and text line up with the rows' icons and titles.
enum OmniboxMetrics {
    static let height: CGFloat = 34
    static let radius: CGFloat = height / 2
    /// The field's side padding: a row's own padding plus the list's.
    static let inset: CGFloat = listPadding + 10
    static let iconWidth: CGFloat = 16
    static let listPadding: CGFloat = 6
    /// Concentric with the rows' 8pt corners.
    static let listRadius: CGFloat = 14
}

/// The address field's backdrop, and the list's. An open edge drops that side
/// of the hairline outline, so the field and the list stacked edge to edge
/// read as one shape.
private struct OmniboxSurface: View {
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let openEdge: VerticalEdge?

    var body: some View {
        RoundedSegment(topRadius: topRadius, bottomRadius: bottomRadius)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedSegment(topRadius: topRadius, bottomRadius: bottomRadius, openEdge: openEdge, inset: 0.5)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
    }
}

/// A rectangle with its own corner radius at the top and at the bottom. With an
/// `openEdge` it's only the outline, without that edge (for stroking).
private struct RoundedSegment: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var openEdge: VerticalEdge? = nil
    /// Pulls the closed edges in, so a stroke stays inside the shape.
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var r = rect.insetBy(dx: inset, dy: inset)
        // The open edge stays at the boundary, so the side lines meet the neighbor's.
        switch openEdge {
        case .top?: r = CGRect(x: r.minX, y: rect.minY, width: r.width, height: r.maxY - rect.minY)
        case .bottom?: r = CGRect(x: r.minX, y: r.minY, width: r.width, height: rect.maxY - r.minY)
        case nil: break
        }
        let limit = min(r.width, r.height) / 2
        let top = min(topRadius, limit)
        let bottom = min(bottomRadius, limit)
        let topLeft = CGPoint(x: r.minX, y: r.minY), topRight = CGPoint(x: r.maxX, y: r.minY)
        let bottomRight = CGPoint(x: r.maxX, y: r.maxY), bottomLeft = CGPoint(x: r.minX, y: r.maxY)

        var path = Path()
        func corner(_ point: CGPoint, toward next: CGPoint, radius: CGFloat) {
            if radius > 0 {
                path.addArc(tangent1End: point, tangent2End: next, radius: radius)
            } else {
                path.addLine(to: point)
            }
        }
        // Clockwise, starting just after the open edge.
        switch openEdge {
        case .bottom?:
            path.move(to: bottomLeft)
            corner(topLeft, toward: topRight, radius: top)
            corner(topRight, toward: bottomRight, radius: top)
            path.addLine(to: bottomRight)
        case .top?:
            path.move(to: topRight)
            corner(bottomRight, toward: bottomLeft, radius: bottom)
            corner(bottomLeft, toward: topLeft, radius: bottom)
            path.addLine(to: topLeft)
        case nil:
            path.move(to: CGPoint(x: r.midX, y: r.minY))
            corner(topRight, toward: bottomRight, radius: top)
            corner(bottomRight, toward: bottomLeft, radius: bottom)
            corner(bottomLeft, toward: topLeft, radius: bottom)
            corner(topLeft, toward: topRight, radius: top)
            path.closeSubpath()
        }
        return path
    }
}

extension View {
    /// The look shared by floating panels (suggestions, the command palette):
    /// a thick material card with a hairline edge and a soft shadow.
    func floatingPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.thickMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
    }
}
