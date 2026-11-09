#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Authors' faces, gathered from everywhere the Mac knows them and put
/// into the community folder for the headset (2 Nov 2026):
/// 1. Origami's own People (the user's photos, else their drawn portraits);
/// 2. Author's pictures of people — the Overview Pictures store the two
///    apps share through their App Group;
/// 3. Knowledge Space's portraits — its People.json (`portraitFile`) and
///    Portraits folder, in the community folder itself or a folder chosen.
/// The first source to have a face for a name wins, in that order. Each
/// face is written once, downscaled to 256 px, and rewritten only when its
/// source changes. Run by Library Upkeep (every ten minutes) and by
/// Settings ▸ Portraits ▸ Import Now.
@MainActor @Observable
final class PortraitPublisher {
    static let shared = PortraitPublisher()

    private(set) var isRunning = false
    private(set) var status = "Not gathered yet."
    @ObservationIgnored private var lastRun = Date.distantPast

    /// The Knowledge Space folder chosen in Settings, when it is not the
    /// community folder itself.
    var knowledgeSpaceFolderName: String? {
        resolveKnowledgeSpaceFolder()?.lastPathComponent
    }
    private static let ksBookmarkKey = "portraitsKnowledgeSpaceFolder"

    func chooseKnowledgeSpaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose Knowledge Space's library folder — the one holding its People.json and Portraits."
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return }
        UserDefaults.standard.set(bookmark, forKey: Self.ksBookmarkKey)
    }

    /// The chosen Knowledge Space folder — its concepts are read from it too.
    var knowledgeSpaceFolder: URL? { resolveKnowledgeSpaceFolder() }

    private func resolveKnowledgeSpaceFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.ksBookmarkKey) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Library Upkeep's beat: at most every ten minutes.
    func publishIfDue(model: AppModel) {
        guard Date.now.timeIntervalSince(lastRun) > 600 else { return }
        publish(model: model)
    }

    func publish(model: AppModel) {
        guard !isRunning, let community = model.index.folderURL else {
            if model.index.folderURL == nil { status = "No community folder chosen." }
            return
        }
        isRunning = true
        lastRun = .now
        defer { isRunning = false }

        // Every face, by name key, the first source winning.
        var faces: [String: (name: String, data: Data, source: String)] = [:]
        func offer(_ name: String, _ data: Data?, _ source: String) {
            let key = OrigamiPortraits.key(name)
            guard !key.isEmpty, key.contains(" "), faces[key] == nil, let data, !data.isEmpty else { return }
            faces[key] = (name, data, source)
        }
        // 1. Origami's People.
        for person in model.people.people {
            let image = model.portraits.original(for: person.localID) ?? model.portraits.portrait(for: person.localID)
            let data = image.flatMap { $0.tiffRepresentation }
            for name in [person.displayName] + person.otherNames { offer(name, data, "origami") }
        }
        // 2. Author's pictures of people.
        let authorFolder = OverviewPictureStore.directoryURL
        for (key, record) in OverviewPictureStore.readIndex(at: authorFolder.appendingPathComponent("index.json"))
        where record.kind == .person && record.deleted != true && record.title != nil {
            guard let file = record.file else { continue }
            let name = record.name ?? String(key.drop { $0 != ":" }.dropFirst())
            offer(name, try? Data(contentsOf: authorFolder.appendingPathComponent(file)), "author")
        }
        // 3. Knowledge Space: the community folder's own, then a chosen folder.
        var ksCount = 0
        for folder in [community, resolveKnowledgeSpaceFolder()].compactMap({ $0 }) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("People.json")),
                  let people = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for person in people {
                guard let file = person["portraitFile"] as? String, !file.isEmpty else { continue }
                let given = person["givenName"] as? String ?? ""
                let family = person["familyName"] as? String ?? ""
                let credit = person["creditName"] as? String ?? ""
                let names = [credit, "\(given) \(family)"] + (person["otherNames"] as? [String] ?? [])
                let image = try? Data(contentsOf: folder.appendingPathComponent(file))
                if image != nil { ksCount += 1 }
                for name in names where !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    offer(name, image, "knowledge-space")
                }
            }
        }

        // Written into the community folder: each face once, small.
        let scoped = community.startAccessingSecurityScopedResource()
        defer { if scoped { community.stopAccessingSecurityScopedResource() } }
        let held = OrigamiPortraits.read(from: community)
        let heldByKey = Dictionary((held?.people ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let folder = community.appendingPathComponent(OrigamiPortraits.folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [OrigamiPortraits.Entry] = []
        var written = 0
        for (key, face) in faces {
            let hash = SHA256.hash(data: face.data).prefix(10).map { String(format: "%02x", $0) }.joined()
            let file = OrigamiPortraits.folderName + "/origami-" + key.replacingOccurrences(of: " ", with: "-") + ".png"
            let url = community.appendingPathComponent(file)
            if heldByKey[key]?.sourceHash != hash || !FileManager.default.fileExists(atPath: url.path) {
                guard let small = Self.thumbnailPNG(face.data, maxPixel: 256) else { continue }
                try? small.write(to: url, options: .atomic)
                written += 1
            }
            entries.append(.init(name: face.name, key: key, file: file, source: face.source, sourceHash: hash))
        }
        entries.sort { $0.key < $1.key }
        if entries != held?.people {
            OrigamiPortraits.write(OrigamiPortraits(modified: .now, people: entries), to: community)
        }
        let bySource = Dictionary(grouping: entries, by: \.source).mapValues(\.count)
        status = "\(entries.count) faces in the community folder — \(bySource["origami"] ?? 0) from People, "
            + "\(bySource["author"] ?? 0) from Author, \(bySource["knowledge-space"] ?? 0) from Knowledge Space"
            + (written > 0 ? "; \(written) written now." : ".")
    }

    /// The image made square-ish and small, as PNG.
    private static func thumbnailPNG(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

/// Knowledge Space's concepts, brought into the concept library by the Mac
/// on its own (9 Nov 2026) — so the headset, which reads the library from
/// the community folder, has them with no file to choose. It looks where
/// Knowledge Space keeps its documents: the folder chosen for its
/// portraits (Settings ▸ Portraits), and a "Knowledge Space" folder inside
/// the community folder. Each `.liquid.json` is read once, then again only
/// when it changes. Run by Library Upkeep (every ten minutes).
@MainActor @Observable
final class KnowledgeSpaceConcepts {
    static let shared = KnowledgeSpaceConcepts()

    private(set) var isRunning = false
    private(set) var status = "Not brought in yet."
    @ObservationIgnored private var lastRun = Date.distantPast
    /// Each document's modification time when last read, by path.
    private static let seenKey = "knowledgeSpaceConceptsSeen"

    func importIfDue(model: AppModel) {
        guard Date.now.timeIntervalSince(lastRun) > 600 else { return }
        importNow(model: model)
    }

    func importNow(model: AppModel) {
        guard !isRunning else { return }
        var folders: [URL] = []
        if let chosen = PortraitPublisher.shared.knowledgeSpaceFolder { folders.append(chosen) }
        if let community = model.index.folderURL {
            folders.append(community.appendingPathComponent("Knowledge Space", isDirectory: true))
        }
        guard !folders.isEmpty else {
            status = "No Knowledge Space folder known — choose it under Portraits."
            return
        }
        isRunning = true
        lastRun = .now
        let seen = UserDefaults.standard.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]
        Task {
            // The changed documents, found off the main thread.
            let changed = await Task.detached(priority: .background) {
                Self.changedDocuments(in: folders, seen: seen)
            }.value
            var report = ConceptLibraryModel.ImportReport()
            var nowSeen = seen
            var read = 0
            // A hundred at a time: the largest documents run to megabytes.
            for batch in stride(from: 0, to: changed.count, by: 100).map({ Array(changed[$0..<min($0 + 100, changed.count)]) }) {
                let docs = await Task.detached(priority: .background) {
                    Self.decode(batch, scopes: folders)
                }.value
                let part = model.conceptLibrary.importConcepts(from: docs)
                report.added += part.added
                report.revised += part.revised
                report.used += part.used
                report.skipped += part.skipped
                read += docs.count
                for file in batch { nowSeen[file.path] = file.modified }
            }
            UserDefaults.standard.set(nowSeen, forKey: Self.seenKey)
            if changed.isEmpty {
                status = "Up to date — \(seen.count) Knowledge Space documents read."
            } else {
                status = "\(read) Knowledge Space document\(read == 1 ? "" : "s") read: \(report.summary)."
                // Into the community folder for the headset at once.
                if let community = model.index.folderURL {
                    _ = model.conceptLibrary.mirror(withCommunity: community)
                }
            }
            isRunning = false
        }
    }

    private struct Found: Sendable {
        let url: URL
        let path: String
        let modified: Double
    }

    private nonisolated static func changedDocuments(in folders: [URL], seen: [String: Double]) -> [Found] {
        var found: [Found] = []
        for folder in folders {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            guard let names = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in names where url.lastPathComponent.hasSuffix(".liquid.json") {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                if seen[url.path] != modified {
                    found.append(Found(url: url, path: url.path, modified: modified))
                }
            }
        }
        return found
    }

    private nonisolated static func decode(_ files: [Found], scopes: [URL]) -> [LiquidDoc] {
        let scoped = scopes.map { $0.startAccessingSecurityScopedResource() }
        defer { for (folder, on) in zip(scopes, scoped) where on { folder.stopAccessingSecurityScopedResource() } }
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: file.url) else { return nil }
            return try? LiquidDoc.decode(data: data, fileURL: file.url)
        }
    }
}

/// Settings ▸ Portraits: where the faces come from, and Import Now.
struct PortraitsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var publisher = PortraitPublisher.shared
    @State private var ksConcepts = KnowledgeSpaceConcepts.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Origami People") { Text("\(model.people.people.count) people").foregroundStyle(.secondary) }
                LabeledContent("Author") { Text("Author\u{2019}s pictures of people, shared with this Mac").foregroundStyle(.secondary) }
                LabeledContent("Knowledge Space") {
                    HStack {
                        Text(publisher.knowledgeSpaceFolderName.map { "The folder \u{201C}\($0)\u{201D} and the community folder" }
                             ?? "The community folder\u{2019}s People.json")
                            .foregroundStyle(.secondary)
                        Button("Choose Folder\u{2026}") { publisher.chooseKnowledgeSpaceFolder() }
                    }
                }
                HStack {
                    Text(publisher.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(publisher.isRunning ? "Importing\u{2026}" : "Import Now") { publisher.publish(model: model) }
                        .disabled(publisher.isRunning)
                }
            } header: {
                Text("Author Pictures")
            } footer: {
                Text("Faces from your People, from Author and from Knowledge Space are gathered into the community folder\u{2019}s Portraits, where Vision Pro shows them on the cards in place of the authors\u{2019} names. Your own People come first, then Author, then Knowledge Space. Library Upkeep gathers new ones every ten minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(ksConcepts.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(ksConcepts.isRunning ? "Bringing In\u{2026}" : "Bring In Now") { ksConcepts.importNow(model: model) }
                        .disabled(ksConcepts.isRunning)
                }
            } header: {
                Text("Knowledge Space Concepts")
            } footer: {
                Text("The concepts in Knowledge Space\u{2019}s documents \u{2014} in the folder chosen above, and in a Knowledge Space folder inside the community folder \u{2014} join your Defined Concepts, and from there every device\u{2019}s, Vision Pro\u{2019}s included. Library Upkeep reads new and changed documents every ten minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
