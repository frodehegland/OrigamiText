import Foundation
import Observation

/// Stores the user's own documents as real `.origamitext` files in the app
/// container (Application Support/Drafts), named by their UUID. Because drafts
/// are ordinary Origami Documents on disk, future features (links between drafts,
/// publishing into the community folder, sidecars) need no format changes.
@MainActor @Observable
final class DraftStore {
    private(set) var documents: [LiquidDoc] = []
    /// Published copies (with their Visual-Meta appendix): read-only.
    private(set) var published: [LiquidDoc] = []
    /// Shelved drafts: out of the working list, deleted nothing. The file
    /// moves between folders whole, so an archived draft keeps its id and
    /// returns exactly as it left.
    private(set) var archived: [LiquidDoc] = []
    let draftsFolder: URL
    let publishedFolder: URL
    let archivedFolder: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        draftsFolder = base.appendingPathComponent("Drafts", isDirectory: true)
        publishedFolder = base.appendingPathComponent("Published", isDirectory: true)
        archivedFolder = base.appendingPathComponent("Archived", isDirectory: true)
        try? FileManager.default.createDirectory(at: draftsFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: publishedFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: archivedFolder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        documents = Self.load(folder: draftsFolder)
        published = Self.load(folder: publishedFolder)
        archived = Self.load(folder: archivedFolder)
    }

    /// Shelves a draft: the file moves to the Archived folder untouched.
    func archive(_ doc: LiquidDoc) throws {
        let destination = archivedFileURL(for: doc.id)
        try FileManager.default.moveItem(at: fileURL(for: doc.id), to: destination)
        documents.removeAll { $0.id == doc.id }
        if let data = try? Data(contentsOf: destination),
           let moved = try? LiquidDoc.decode(data: data, fileURL: destination) {
            archived.append(moved)
            archived.sort { $0.listedDate > $1.listedDate }
        }
    }

    /// Returns a shelved draft to Drafts, exactly as it was archived.
    func unarchive(_ doc: LiquidDoc) throws {
        let destination = fileURL(for: doc.id)
        try FileManager.default.moveItem(at: archivedFileURL(for: doc.id), to: destination)
        archived.removeAll { $0.id == doc.id }
        if let data = try? Data(contentsOf: destination),
           let moved = try? LiquidDoc.decode(data: data, fileURL: destination) {
            documents.append(moved)
            documents.sort { $0.listedDate > $1.listedDate }
        }
    }

    private func archivedFileURL(for id: String) -> URL {
        archivedFolder
            .appendingPathComponent(id)
            .appendingPathExtension(LiquidDoc.fileExtension)
    }

    private nonisolated static func load(folder: URL) -> [LiquidDoc] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == LiquidDoc.fileExtension }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? LiquidDoc.decode(data: data, fileURL: url)
            }
            .sorted { $0.listedDate > $1.listedDate }
    }

    /// Publication: the exported copy (appendix and all) moves to Published
    /// and the editable draft is retired.
    func markPublished(draftID: String, publishedDoc: LiquidDoc) throws {
        let data = try publishedDoc.jsonData()
        let url = publishedFolder.appendingPathComponent(draftID).appendingPathExtension(LiquidDoc.fileExtension)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: fileURL(for: draftID))
        documents.removeAll { $0.id == draftID }
        if let doc = try? LiquidDoc.decode(data: data, fileURL: url) {
            published.removeAll { $0.id == doc.id }
            published.insert(doc, at: 0)
            published.sort { $0.listedDate > $1.listedDate }
        }
    }

    func isPublished(_ id: String) -> Bool {
        published.contains { $0.id == id }
    }

    @discardableResult
    func create(author: String) throws -> LiquidDoc {
        let created = Date.now
        let id = LiquidAddress.makeID(author: author, created: created) { candidate in
            self.documents.contains { $0.id == candidate }
        }
        let doc = LiquidDoc(format: LiquidDoc.knownFormat, id: id, title: "Untitled",
                            author: author, created: created, body: [], links: [], wraps: nil,
                            fileURL: fileURL(for: id))
        try save(doc)
        return doc
    }

    func save(_ doc: LiquidDoc) throws {
        let data = try doc.jsonData()
        try data.write(to: fileURL(for: doc.id), options: .atomic)
        if let index = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[index] = doc
        } else {
            documents.insert(doc, at: 0)
        }
    }

    func delete(_ doc: LiquidDoc) {
        try? FileManager.default.removeItem(at: fileURL(for: doc.id))
        documents.removeAll { $0.id == doc.id }
    }

    func fileURL(for id: String) -> URL {
        draftsFolder
            .appendingPathComponent(id)
            .appendingPathExtension(LiquidDoc.fileExtension)
    }
}

/// Editing buffer for one draft. Owned by the app model rather than view
/// state so richer editing (links, structure) can build on it later.
@MainActor @Observable
final class DraftEditor {
    private(set) var original: LiquidDoc
    var title: String { didSet { hasUnsavedChanges = true } }
    var author: String { didSet { hasUnsavedChanges = true } }
    var bodyText: String { didSet { hasUnsavedChanges = true } }
    /// "For the attention of" — the people this document addresses.
    var attention: [String] { didSet { hasUnsavedChanges = true } }
    /// Human-assigned date; nil means the document goes by its creation
    /// timestamp, which is never editable.
    var date: LiquidDate? { didSet { hasUnsavedChanges = true } }
    private(set) var hasUnsavedChanges = false

    var docID: String { original.id }

    /// BibTeX records from pasted citations, keyed by derived address;
    /// attached to their links on save (the link carries its provenance).
    private(set) var pendingReferences: [String: String] = [:]

    func registerReference(address: String, bibtex: String) {
        pendingReferences[address] = bibtex
        hasUnsavedChanges = true
    }
    var createdText: String { original.created.formatted(date: .long, time: .shortened) }

    init(doc: LiquidDoc) {
        original = doc
        title = doc.title
        author = doc.author
        bodyText = doc.bodyEditingText
        attention = doc.attention
        date = doc.date
    }

    func addAttention(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !attention.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return }
        attention.append(trimmed)
    }

    func removeAttention(_ name: String) {
        attention.removeAll { $0 == name }
    }

    /// The draft as it would be saved right now. Existing links are
    /// preserved, and document references pasted into the text (citations
    /// carrying a UUID, with or without a #fragment) become structured
    /// `cites` links.
    func buildDocument() -> LiquidDoc {
        var body = LiquidDoc.parseBody(from: bodyText)
        // Transcript drafts keep their attributions through editing: a
        // paragraph still opening with a name this document already knows
        // as a speaker ("Mark Anderson: …") keeps its speaker field. Only
        // known names qualify — no guessing on arbitrary "Word:" prefixes.
        let knownSpeakers = Set((original.body ?? []).compactMap(\.speaker))
        if !knownSpeakers.isEmpty {
            body = body.map { paragraph in
                guard let speaker = knownSpeakers.first(where: { paragraph.text.hasPrefix("\($0):") })
                else { return paragraph }
                var attributed = paragraph
                attributed.speaker = speaker
                return attributed
            }
        }
        var links = original.links
        for detected in LiquidDoc.detectedLinks(in: body)
        where detected.to != original.id
            && !links.contains(where: { $0.to == detected.to && $0.fragment == detected.fragment }) {
            links.append(detected)
        }
        // Attach pasted citation records to their links.
        links = links.map { link in
            guard link.bibtex == nil, let bibtex = pendingReferences[link.to] else { return link }
            var linked = link
            linked.bibtex = bibtex
            return linked
        }
        return LiquidDoc(format: original.format,
                         id: original.id,
                         title: title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title,
                         author: author,
                         created: original.created,
                         body: body,
                         links: links,
                         wraps: nil,
                         attention: attention,
                         date: date,
                         aiOnBehalf: original.aiOnBehalf,
                         onBehalfOf: original.onBehalfOf,
                         documentType: original.documentType,
                         fileURL: original.fileURL)
    }

    func markSaved(_ doc: LiquidDoc) {
        original = doc
        hasUnsavedChanges = false
    }
}
