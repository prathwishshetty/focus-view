import SwiftUI
import WebKit

/// Settings ▸ Extensions: add, update, turn on and off, and remove web extensions.
struct ExtensionsSettings: View {
    private let manager = ExtensionManager.shared
    @State private var selection: InstalledExtension.ID?
    @State private var removing: InstalledExtension.ID?
    @State private var isWorking = false
    @State private var status: String?
    @State private var failure: String?

    private static let uBlockName = "uBlock Origin Lite"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a web extension from an unpacked folder (with a manifest.json) or a .zip of one. Focus runs Safari-style web extensions; content blockers like uBlock Origin Lite work best.")
                .settingsFootnote()

            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(manager.installed) { record in
                        ExtensionRow(record: record)
                            .tag(record.id)
                    }
                }
                .contextMenu(forSelectionType: InstalledExtension.ID.self) { ids in
                    if let id = ids.first {
                        if manager.contexts[id]?.optionsPageURL != nil {
                            Button("Extension Settings…") { manager.openOptions(for: id) }
                        }
                        Button("Reload") { reload(id) }
                        Button("Remove…", role: .destructive) { removing = id }
                    }
                }
                .listStyle(.bordered)
                .overlay {
                    if manager.installed.isEmpty {
                        ContentUnavailableView {
                            Label("No Extensions", systemImage: "puzzlepiece.extension")
                        } description: {
                            Text("Add one with +, or install uBlock Origin Lite to block ads and trackers.")
                        }
                    }
                }

                // The classic macOS +/− bar under a list.
                HStack(spacing: 0) {
                    Button(action: add) {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add an extension from a folder or a .zip")
                    Divider().frame(height: 16)
                    Button {
                        removing = selection
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection == nil)
                    .help("Remove the selected extension")
                    Spacer()
                    if isWorking {
                        ProgressView().controlSize(.small).padding(.trailing, 8)
                    }
                    Button(hasUBlock ? "Update \(Self.uBlockName)" : "Install \(Self.uBlockName)", action: installUBlock)
                        .controlSize(.small)
                        .padding(.trailing, 6)
                        .help("Download the latest Safari build of uBlock Origin Lite from GitHub")
                }
                .buttonStyle(.borderless)
                .disabled(isWorking)
                .padding(.vertical, 3)
                .background(.bar)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))

            HStack {
                if let status {
                    Text(status).settingsFootnote()
                }
                Spacer()
                Link("uBlock Origin Lite releases", destination: ExtensionInstaller.uBlockReleasesPage)
                    .font(.footnote)
            }
        }
        .padding(20)
        .frame(height: 460)
        .alert("Couldn't add the extension", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .confirmationDialog(
            "Remove “\(removing.map { manager.displayName(for: $0) } ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let id = removing {
                    manager.remove(id)
                    if selection == id { selection = nil }
                }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This deletes the extension and its settings and data.")
        }
    }

    private var hasUBlock: Bool {
        manager.installedID(named: Self.uBlockName) != nil
    }

    private func add() {
        run { try await ExtensionInstaller.chooseAndInstall() }
    }

    private func installUBlock() {
        let updating = hasUBlock
        run(verb: updating ? "Updated" : "Installed") { try await ExtensionInstaller.installUBlockOriginLite() }
    }

    private func reload(_ id: String) {
        Task {
            await manager.reload(id)
            status = "Reloaded \(manager.displayName(for: id))."
        }
    }

    private func run(verb: String = "Added", _ work: @escaping () async throws -> String?) {
        isWorking = true
        status = nil
        Task {
            defer { isWorking = false }
            do {
                if let name = try await work() { status = "\(verb) \(name)." }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct ExtensionRow: View {
    let record: InstalledExtension

    private var manager: ExtensionManager { .shared }

    var body: some View {
        let webExtension = manager.extensions[record.id]
        let context = manager.contexts[record.id]
        let issues = context?.errors ?? webExtension?.errors ?? []

        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = webExtension?.icon(for: CGSize(width: 32, height: 32)) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .opacity(record.isEnabled ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(manager.displayName(for: record.id)).fontWeight(.medium)
                    if let version = webExtension?.displayVersion {
                        Text(version).foregroundStyle(.secondary)
                    }
                }
                if let error = manager.loadErrors[record.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if let description = webExtension?.displayDescription {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 12) {
                    if context?.optionsPageURL != nil {
                        Button("Settings…") { manager.openOptions(for: record.id) }
                    }
                    if !issues.isEmpty {
                        Label("^[\(issues.count) issue](inflect: true)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(issues.map(\.localizedDescription).joined(separator: "\n"))
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            .help(webExtension.map { ExtensionPermissionText.summary(of: $0).joined(separator: "\n") } ?? "")

            Spacer()

            Toggle("Enabled", isOn: Binding(
                get: { record.isEnabled },
                set: { manager.setEnabled($0, for: record.id) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(webExtension == nil)
        }
        .padding(.vertical, 4)
    }
}
