import SwiftUI
import UniformTypeIdentifiers

/// A view module packaged for exchange: the manifest a running app can
/// read, with the Swift source embedded. Saved as a `.origamiview` file.
/// Modules run as compiled Swift, so importing one this app doesn't
/// already contain keeps it on the shelf ("awaiting build") — its source
/// exports for Xcode, where one registry line makes it part of the app.
nonisolated struct ModuleArchive: Codable, Identifiable {
    var format = "origami-view-module/1"
    let id: String
    let name: String
    let systemImage: String
    /// The Swift file name the source belongs in, e.g. "WeaveView.swift".
    let fileName: String
    let source: String
}

/// Sharing plumbing for view modules: bundled sources (a build-time
/// snapshot shipped as ModuleSources.json), the imported-modules shelf in
/// Application Support, and the import/export transforms between them.
@MainActor
enum ModuleExchange {

    static let origamiViewType = UTType(filenameExtension: "origamiview",
                                        conformingTo: .json) ?? .json

    // MARK: Bundled sources

    private nonisolated struct BundledSources: Codable {
        struct Entry: Codable {
            let file: String
            let source: String
        }
        let format: String
        let modules: [String: Entry]
    }

    /// The snapshot of module sources baked into this build. Regenerate
    /// ModuleSources.json when a module changes, so exports stay current.
    private static let bundled: [String: BundledSources.Entry] = {
        guard let url = Bundle.main.url(forResource: "ModuleSources", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(BundledSources.self, from: data)
        else { return [:] }
        return decoded.modules
    }()

    /// The exchange archive for an installed module: an imported copy if
    /// one is on the shelf, else the build's own snapshot.
    static func archive(for module: LibraryViewModule) -> ModuleArchive? {
        if let imported = importedArchives().first(where: { $0.id == module.id }) {
            return imported
        }
        guard let entry = bundled[module.id] else { return nil }
        return ModuleArchive(id: module.id, name: module.name,
                             systemImage: module.systemImage,
                             fileName: entry.file, source: entry.source)
    }

    // MARK: The imported shelf

    static var shelfFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("ViewModules", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func importedArchives() -> [ModuleArchive] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: shelfFolder, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "origamiview" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ModuleArchive.self, from: data)
            }
            .sorted { $0.name < $1.name }
    }

    /// Whether an imported module's code is part of this build — running —
    /// or still awaiting its pass through Xcode.
    static func isActive(_ archive: ModuleArchive) -> Bool {
        LibraryViewRegistry.module(id: archive.id) != nil
    }

    static func removeImported(_ archive: ModuleArchive) {
        try? FileManager.default.removeItem(at: shelfURL(for: archive.id))
    }

    private static func shelfURL(for id: String) -> URL {
        shelfFolder.appendingPathComponent(id).appendingPathExtension("origamiview")
    }

    // MARK: Import

    enum ImportError: LocalizedError {
        case unreadable
        case notAModule

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file could not be read."
            case .notAModule: "This file is not an Origami view module or a Swift view-module file."
            }
        }
    }

    /// Imports a `.origamiview` archive or a bare `.swift` module file
    /// onto the shelf; returns the stored archive.
    @discardableResult
    static func importModule(at url: URL) throws -> ModuleArchive {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        let archive: ModuleArchive
        if url.pathExtension.lowercased() == "swift" {
            guard let source = String(data: data, encoding: .utf8) else {
                throw ImportError.unreadable
            }
            archive = wrap(source: source, fileName: url.lastPathComponent)
        } else if let decoded = try? JSONDecoder().decode(ModuleArchive.self, from: data),
                  decoded.format.hasPrefix("origami-view-module/") {
            archive = decoded
        } else {
            throw ImportError.notAModule
        }
        let stored = try JSONEncoder().encode(archive)
        try stored.write(to: shelfURL(for: archive.id), options: .atomic)
        return archive
    }

    /// Reads the module declaration out of a bare Swift file: the id,
    /// name, and symbol its `LibraryViewModule` declares, with the file
    /// name as the fallback identity.
    private nonisolated static func wrap(source: String, fileName: String) -> ModuleArchive {
        func field(_ label: String) -> String? {
            let pattern = "\(label):\\s*\"([^\"]+)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source,
                                               range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
        let baseName = (fileName as NSString).deletingPathExtension
        return ModuleArchive(id: field("id") ?? baseName.lowercased(),
                             name: field("name") ?? baseName,
                             systemImage: field("systemImage") ?? "puzzlepiece.extension",
                             fileName: fileName,
                             source: source)
    }

    // MARK: Export

    /// Saves the module's Swift source — the file another user drops into
    /// their Xcode project and registers with one line.
    static func exportSwiftFile(_ archive: ModuleArchive) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.swiftSource]
        panel.nameFieldStringValue = archive.fileName
        panel.message = "The exported file goes into the Xcode project, plus one line in LibraryViewRegistry.modules."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? archive.source.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Saves the module as a `.origamiview` archive — what another copy of
    /// Origami Text imports directly.
    static func exportOrigamiView(_ archive: ModuleArchive) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [origamiViewType]
        panel.nameFieldStringValue = "\(archive.id).origamiview"
        panel.message = "Another user imports this in Settings → View Modules → Import Module."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(archive) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
