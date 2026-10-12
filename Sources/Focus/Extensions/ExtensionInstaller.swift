import AppKit
import WebKit

/// Adds web extensions from an unpacked folder, a `.zip` (or `.xpi`) archive,
/// or uBlock Origin Lite's latest release on GitHub.
///
/// The files are copied into Application Support, so the original can be moved
/// or deleted, and the sandbox doesn't need ongoing access to it. Adding an
/// extension that's already installed (same name) updates it in place.
@MainActor
enum ExtensionInstaller {
    enum InstallError: LocalizedError {
        case noManifest
        case unzipFailed
        case noRelease

        var errorDescription: String? {
            switch self {
            case .noManifest: "This doesn't look like a web extension: there's no manifest.json in it."
            case .unzipFailed: "The archive couldn't be unpacked."
            case .noRelease: "Couldn't find a Safari build in uBlock Origin Lite's latest release."
            }
        }
    }

    /// Where uBlock Origin Lite publishes builds, including one for Safari (WebKit).
    static let uBlockReleasesAPI = URL(string: "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest")!
    static let uBlockReleasesPage = URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases")!

    /// Asks for a folder or archive, then installs it. Returns the extension's name, or nil if cancelled.
    static func chooseAndInstall() async throws -> String? {
        let panel = NSOpenPanel()
        panel.title = "Add Extension"
        panel.message = "Choose an unpacked extension folder (with a manifest.json), or a .zip of one."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try await install(from: url)
    }

    /// Downloads the latest uBlock Origin Lite for Safari and installs (or updates) it.
    static func installUBlockOriginLite() async throws -> String? {
        var request = URLRequest(url: uBlockReleasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)

        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
            }
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".safari.zip") }) else {
            throw InstallError.noRelease
        }
        let (archive, _) = try await URLSession.shared.data(from: asset.browserDownloadUrl)

        let staging = try makeStagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent(asset.name)
        try archive.write(to: file)
        return try await install(from: file, confirm: false)
    }

    /// Copies an extension into place, checks it, asks the user, and loads it.
    static func install(from source: URL, confirm: Bool = true) async throws -> String? {
        let manager = ExtensionManager.shared
        let staging = try makeStagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }

        // Copy (or unpack) into our own container first.
        let unpacked = staging.appendingPathComponent("extension", isDirectory: true)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try FileManager.default.copyItem(at: source, to: unpacked)
        } else {
            let archive = staging.appendingPathComponent("archive.zip")
            try FileManager.default.copyItem(at: source, to: archive)
            try await unzip(archive, to: unpacked)
        }
        let root = try manifestRoot(in: unpacked)

        // Parse it, so a broken extension never replaces a working one.
        let candidate = try await WKWebExtension(resourceBaseURL: root)
        let name = candidate.displayName ?? source.deletingPathExtension().lastPathComponent
        let existingID = manager.installedID(named: candidate.displayName)

        if confirm, existingID == nil, !askToAdd(candidate, name: name) { return nil }

        let id = existingID ?? UUID().uuidString.lowercased()
        guard let folder = ExtensionManager.folder(for: id) else { throw CocoaError(.fileNoSuchFile) }
        if existingID != nil { manager.prepareForUpdate(id) }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root, to: folder)

        // Load from its final home, so resource URLs point there.
        let installed = try await WKWebExtension(resourceBaseURL: folder)
        manager.didInstall(installed, id: id)
        return name
    }

    private static func askToAdd(_ webExtension: WKWebExtension, name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(name)”?"
        let lines = ExtensionPermissionText.summary(of: webExtension)
        alert.informativeText = lines.isEmpty
            ? "It doesn't ask for any permissions."
            : "It will be able to:\n" + lines.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func makeStagingFolder() throws -> URL {
        guard let directory = ExtensionManager.directory else { throw CocoaError(.fileNoSuchFile) }
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Unpacks a zip with the system's `ditto`, off the main thread.
    private static func unzip(_ archive: URL, to destination: URL) async throws {
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, destination.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else { throw InstallError.unzipFailed }
    }

    /// The folder holding manifest.json: the top level, or a single folder inside it.
    private static func manifestRoot(in folder: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let children = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        if children.count == 1, let only = children.first,
           fileManager.fileExists(atPath: only.appendingPathComponent("manifest.json").path) {
            return only
        }
        throw InstallError.noManifest
    }
}
