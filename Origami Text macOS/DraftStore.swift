import AppKit
import Foundation
import Observation

/// Stores the user's own documents as Author `.liquid` packages in the
/// app container (Application Support/Drafts), named by their id — so a
/// draft is one editable file both apps open. The library, the reader
/// and the exporters see each draft as the `LiquidDoc` derived from its
/// package (see `LiquidRichText`); published copies stay `.origamitext`,
/// the format's immutable record.
@MainActor @Observable
final class DraftStore {
    private(set) var documents: [LiquidDoc] = []
    /// Published copies (with their Visual-Meta appendix): read-only.
    private(set) var published: [LiquidDoc] = []
    /// Shelved drafts: out of the working list, deleted nothing. The
    /// package moves between folders whole, so an archived draft keeps
    /// its id and returns exactly as it left.
    private(set) var archived: [LiquidDoc] = []
    let draftsFolder: URL
    let publishedFolder: URL
    let archivedFolder: URL
    /// Where a draft's former `.origamitext` file goes once it has become
    /// a package — kept, never deleted.
    let migratedFolder: URL

    /// The packages behind the drafts, by id: the editor's text and the
    /// members Author keeps that the document model does not.
    @ObservationIgnored private var packages: [String: LiquidPackage] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        draftsFolder = base.appendingPathComponent("Drafts", isDirectory: true)
        publishedFolder = base.appendingPathComponent("Published", isDirectory: true)
        archivedFolder = base.appendingPathComponent("Archived", isDirectory: true)
        migratedFolder = draftsFolder.appendingPathComponent("Migrated", isDirectory: true)
        for folder in [draftsFolder, publishedFolder, archivedFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        reload()
    }

    func reload() {
        migrateLegacyDrafts()
        let loaded = loadPackages(in: draftsFolder)
        packages = loaded.packages
        documents = loaded.documents
        published = Self.loadJSON(folder: publishedFolder)
        // Archived drafts: packages, and any `.origamitext` shelved before
        // the package era (converted when brought back).
        let archivedPackages = loadPackages(in: archivedFolder)
        archived = (archivedPackages.documents + Self.loadJSON(folder: archivedFolder))
            .sorted { $0.listedDate > $1.listedDate }
    }

    /// The package behind a draft, for the editor.
    func package(for id: String) -> LiquidPackage? { packages[id] }

    // MARK: Loading

    private var fallbackAuthor: String {
        UserDefaults.standard.string(forKey: "authorName").flatMap { $0.isEmpty ? nil : $0 } ?? NSFullUserName()
    }

    private func loadPackages(in folder: URL) -> (packages: [String: LiquidPackage], documents: [LiquidDoc]) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        var packages: [String: LiquidPackage] = [:]
        var documents: [LiquidDoc] = []
        for url in urls where url.pathExtension.lowercased() == LiquidPackage.fileExtension {
            guard let package = try? LiquidPackage.read(at: url) else { continue }
            let doc = LiquidRichText.document(from: package, fileURL: url, fallbackAuthor: fallbackAuthor)
            packages[doc.id] = package
            documents.append(doc)
        }
        documents.sort { $0.listedDate > $1.listedDate }
        return (packages, documents)
    }

    private nonisolated static func loadJSON(folder: URL) -> [LiquidDoc] {
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

    /// Every `.origamitext` draft becomes a `.liquid` package once; the
    /// original moves to Drafts/Migrated, kept. Nothing is lost if the
    /// conversion fails: the file stays where it was and is simply not
    /// listed, so the failure is visible.
    private func migrateLegacyDrafts() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: draftsFolder, includingPropertiesForKeys: nil)) ?? []
        let legacy = urls.filter { $0.pathExtension.lowercased() == LiquidDoc.fileExtension }
        guard !legacy.isEmpty else { return }
        try? FileManager.default.createDirectory(at: migratedFolder, withIntermediateDirectories: true)
        for url in legacy {
            guard let data = try? Data(contentsOf: url),
                  let doc = try? LiquidDoc.decode(data: data, fileURL: url) else { continue }
            let destination = fileURL(for: doc.id)
            // A package already there wins — the file is an older copy.
            if !FileManager.default.fileExists(atPath: destination.path) {
                let package = LiquidRichText.package(for: doc)
                guard (try? package.write(to: destination)) != nil else { continue }
            }
            let parked = migratedFolder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: parked)
            try? FileManager.default.moveItem(at: url, to: parked)
        }
    }

    // MARK: Archive

    /// Shelves a draft: the package moves to the Archived folder untouched.
    func archive(_ doc: LiquidDoc) throws {
        let destination = archivedFileURL(for: doc.id)
        try FileManager.default.moveItem(at: fileURL(for: doc.id), to: destination)
        documents.removeAll { $0.id == doc.id }
        packages.removeValue(forKey: doc.id)
        if let package = try? LiquidPackage.read(at: destination) {
            archived.append(LiquidRichText.document(from: package, fileURL: destination,
                                                    fallbackAuthor: fallbackAuthor))
            archived.sort { $0.listedDate > $1.listedDate }
        }
    }

    /// Returns a shelved draft to Drafts, exactly as it was archived. A
    /// draft shelved as `.origamitext` comes back as a package.
    func unarchive(_ doc: LiquidDoc) throws {
        let destination = fileURL(for: doc.id)
        let shelvedPackage = archivedFileURL(for: doc.id)
        if FileManager.default.fileExists(atPath: shelvedPackage.path) {
            try FileManager.default.moveItem(at: shelvedPackage, to: destination)
        } else {
            let legacy = archivedFolder.appendingPathComponent(doc.id)
                .appendingPathExtension(LiquidDoc.fileExtension)
            let package = LiquidRichText.package(for: doc)
            try package.write(to: destination)
            try? FileManager.default.createDirectory(at: migratedFolder, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: legacy,
                                              to: migratedFolder.appendingPathComponent(legacy.lastPathComponent))
        }
        archived.removeAll { $0.id == doc.id }
        if let package = try? LiquidPackage.read(at: destination) {
            let moved = LiquidRichText.document(from: package, fileURL: destination,
                                                fallbackAuthor: fallbackAuthor)
            packages[moved.id] = package
            documents.append(moved)
            documents.sort { $0.listedDate > $1.listedDate }
        }
    }

    private func archivedFileURL(for id: String) -> URL {
        archivedFolder
            .appendingPathComponent(id)
            .appendingPathExtension(LiquidPackage.fileExtension)
    }

    // MARK: Publishing

    /// Publication: the exported copy (appendix and all) moves to Published
    /// and the editable draft is retired.
    func markPublished(draftID: String, publishedDoc: LiquidDoc) throws {
        let data = try publishedDoc.jsonData()
        let url = publishedFolder.appendingPathComponent(draftID).appendingPathExtension(LiquidDoc.fileExtension)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: fileURL(for: draftID))
        documents.removeAll { $0.id == draftID }
        packages.removeValue(forKey: draftID)
        if let doc = try? LiquidDoc.decode(data: data, fileURL: url) {
            published.removeAll { $0.id == doc.id }
            published.insert(doc, at: 0)
            published.sort { $0.listedDate > $1.listedDate }
        }
    }

    func isPublished(_ id: String) -> Bool {
        published.contains { $0.id == id }
    }

    // MARK: Creating and saving

    @discardableResult
    func create(author: String, documentType: String? = nil,
                onBehalfOf: String? = nil) throws -> LiquidDoc {
        let created = Date.now
        let id = LiquidAddress.makeID(author: author, created: created) { candidate in
            self.documents.contains { $0.id == candidate }
        }
        let doc = LiquidDoc(format: LiquidDoc.knownFormat, id: id, title: "Untitled",
                            author: author, created: created, body: [], links: [], wraps: nil,
                            onBehalfOf: onBehalfOf, documentType: documentType,
                            fileURL: fileURL(for: id))
        try save(doc)
        return doc
    }

    /// Saves a document made elsewhere (an import, a lift, a transcript):
    /// its body becomes the package's text. A package already behind the
    /// id keeps everything Author stores beyond the document.
    func save(_ doc: LiquidDoc) throws {
        let package = LiquidRichText.package(for: doc, preserving: packages[doc.id])
        try package.write(to: fileURL(for: doc.id))
        packages[doc.id] = package
        var saved = doc
        saved.tables = doc.tables
        replace(saved)
    }

    /// Saves the editor's text as the package, under the document's
    /// fields; returns the document as derived from what was written,
    /// which is what the library now lists.
    @discardableResult
    func save(text: NSAttributedString, citations: [AuthorCitation],
              exportSettings: ExportSettings, for doc: LiquidDoc) throws -> LiquidDoc {
        var package = packages[doc.id] ?? LiquidPackage(text: text, title: doc.title)
        package.text = NSAttributedString(attributedString: text)
        package.title = doc.title
        package.citations = citations.sorted { $0.identifier < $1.identifier }
        package.exportSettings = exportSettings
        package.glossaryEntries = LiquidRichText.glossaryEntries(updating: package.glossaryEntries,
                                                                  with: doc.concepts, date: doc.listedDate)
        package.origamiJSON = LiquidRichText.origamiRecord(for: doc)
        let url = fileURL(for: doc.id)
        try package.write(to: url)
        packages[doc.id] = package
        let derived = LiquidRichText.document(from: package, fileURL: url, fallbackAuthor: fallbackAuthor)
        replace(derived)
        return derived
    }

    private func replace(_ doc: LiquidDoc) {
        if let index = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[index] = doc
        } else {
            documents.insert(doc, at: 0)
        }
        documents.sort { $0.listedDate > $1.listedDate }
    }

    /// Deletion goes by way of the Trash — a deleted draft or note is
    /// recoverable there.
    func delete(_ doc: LiquidDoc) {
        try? FileManager.default.trashItem(at: fileURL(for: doc.id), resultingItemURL: nil)
        documents.removeAll { $0.id == doc.id }
        packages.removeValue(forKey: doc.id)
    }

    /// Deletes a published copy the same way: the file goes to the Trash.
    func trashPublished(_ doc: LiquidDoc) {
        let url = publishedFolder
            .appendingPathComponent(doc.id)
            .appendingPathExtension(LiquidDoc.fileExtension)
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        published.removeAll { $0.id == doc.id }
    }

    func fileURL(for id: String) -> URL {
        draftsFolder
            .appendingPathComponent(id)
            .appendingPathExtension(LiquidPackage.fileExtension)
    }
}

/// Editing buffer for one draft: the text as the rich editor edits it
/// (shared storage — the text view writes straight into it), the
/// citation records the text places, and the document's fields. Owned by
/// the app model rather than view state so saving and exporting can
/// reach it from anywhere.
@MainActor @Observable
final class DraftEditor {
    private(set) var original: LiquidDoc
    var title: String { didSet { hasUnsavedChanges = true } }
    var author: String { didSet { hasUnsavedChanges = true } }
    /// "For the attention of" — the people this document addresses.
    var attention: [String] { didSet { hasUnsavedChanges = true } }
    /// Whose words this document carries when not the author's own —
    /// set by lifting from a transcript, or by hand for pasted email
    /// text and the like. Export declares it, per the convention.
    var onBehalfOf: String? { didSet { hasUnsavedChanges = true } }
    /// Human-assigned date; nil means the document goes by its creation
    /// timestamp, which is never editable.
    var date: LiquidDate? { didSet { hasUnsavedChanges = true } }
    private(set) var hasUnsavedChanges = false

    /// The live text, in Author's shape. The editor's text view uses this
    /// very storage, so there is one copy of the words.
    @ObservationIgnored let textStorage = NSTextStorage()
    /// Citation records placed in the text, by identifier.
    var citations: [String: AuthorCitation] = [:]
    /// The package the draft came from, for what it keeps beyond the text.
    @ObservationIgnored private(set) var package: LiquidPackage?
    /// The editor's text view controller — commands (the Format menu, the
    /// citation sheet) reach the caret through it. Owned here so the menu
    /// can find it before the view is on screen.
    @ObservationIgnored let controller = RichTextController()

    /// Requests from menus for the sheets the editor view presents.
    var requestCitation = false
    var requestTable = false
    var requestLink = false
    /// Export… asks the Origami EPUB questions first (the export sheet).
    var requestExport = false
    /// What the export asks — Author's front-matter settings — kept with
    /// the draft (see `ExportSettings`).
    var exportSettings: ExportSettings { didSet { hasUnsavedChanges = true } }
    /// The document's own Defined Concepts: defined here, or carried in
    /// from Author's glossary. On save they go into the package's
    /// `glossary.json` (Author's) and on export into the EPUB's record.
    var concepts: [LiquidDoc.Concept] { didSet { hasUnsavedChanges = true } }
    /// The shared library, for the concepts the text mentions that the
    /// document has not defined itself — they join the document at
    /// export as Author's export does. Set by the app model.
    @ObservationIgnored weak var conceptLibrary: ConceptLibraryModel?

    /// A concept defined from this document: into its own list (one per
    /// id), where the library's record stands as the document's copy.
    func addConcept(_ concept: LiquidDoc.Concept) {
        if let index = concepts.firstIndex(where: { $0.id == concept.id }) {
            concepts[index] = concept
        } else {
            concepts.append(concept)
        }
    }

    var docID: String { original.id }

    /// The text as plain words — for a title suggestion, an emptiness check.
    var bodyText: String { textStorage.string }

    init(doc: LiquidDoc, package: LiquidPackage? = nil) {
        original = doc
        title = doc.title
        author = doc.author
        attention = doc.attention
        onBehalfOf = doc.onBehalfOf
        date = doc.date
        self.package = package
        exportSettings = package?.exportSettings ?? ExportSettings()
        concepts = doc.concepts
        var citations: [String: AuthorCitation] = [:]
        for citation in package?.citations ?? [] { citations[citation.identifier] = citation }
        let text = package?.text ?? LiquidRichText.attributedString(from: doc, citations: &citations)
        self.citations = citations
        textStorage.setAttributedString(text)
    }

    var citationList: [AuthorCitation] { citations.values.sorted { $0.identifier < $1.identifier } }

    /// The text view reports every edit here.
    func noteTextChanged() {
        hasUnsavedChanges = true
    }

    /// Records a citation the text now places.
    func addCitation(_ citation: AuthorCitation) {
        citations[citation.identifier] = citation
        hasUnsavedChanges = true
    }

    /// Plain words into the text at the end (a quotation a new reply
    /// opens with) — one body paragraph per line.
    func insertPlainText(_ text: String) {
        let doc = LiquidDoc(format: original.format, id: original.id, title: title, author: author,
                            created: original.created, body: LiquidDoc.parseBody(from: text),
                            links: [], wraps: nil, fileURL: original.fileURL)
        var citations = self.citations
        let piece = LiquidRichText.attributedString(from: doc, citations: &citations)
        self.citations = citations
        appendParagraphs(piece)
    }

    /// Adds an image to the document as a paragraph of its own at the
    /// end (the editor's own insert goes to the caret), returning the
    /// attachment. The bytes live in the attachment's file wrapper.
    @discardableResult
    func insertImage(data: Data, suggestedName: String?, alt: String? = nil) -> NSTextAttachment {
        let ext = Self.imageExtension(name: suggestedName, data: data)
        let filename = "img-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        let attachment = LiquidRichText.imageAttachment(data: data, filename: filename)
        var citations = self.citations
        let piece = NSMutableAttributedString(attributedString: LiquidRichText.attachmentParagraph(attachment))
        if let alt, !alt.isEmpty {
            piece.append(NSAttributedString(string: "\n", attributes: AuthorStyle.attachment.attributes))
            piece.append(LiquidRichText.inlineAttributed(alt, style: .attachmentDetails,
                                                         citations: &citations, references: []))
        }
        appendParagraphs(piece)
        return attachment
    }

    private func appendParagraphs(_ piece: NSAttributedString) {
        let storage = textStorage
        storage.beginEditing()
        if storage.length > 0, !(storage.string.hasSuffix("\n")) {
            let attributes = storage.attributes(at: storage.length - 1, effectiveRange: nil)
            storage.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        storage.append(piece)
        storage.endEditing()
        hasUnsavedChanges = true
    }

    /// The file extension for an inserted image: from its name, else
    /// sniffed from the bytes' magic number, defaulting to png.
    static func imageExtension(name: String?, data: Data) -> String {
        if let name {
            let ext = (name as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext != "tiff", ext != "tif" { return ext }
        }
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "jpeg" }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return "png" }
        if bytes.count >= 3, bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 { return "gif" }
        return "png"
    }

    /// BibTeX records from pasted library citations, keyed by address;
    /// attached to their links on save (the link carries its provenance).
    private(set) var pendingReferences: [String: String] = [:]

    func registerReference(address: String, bibtex: String) {
        pendingReferences[address] = bibtex
        hasUnsavedChanges = true
    }

    /// Corrected BibTeX from Preflight, keyed by reference id (a link's
    /// target address or an external reference's id). Applied in
    /// `buildDocument`, and to the citation record itself.
    private(set) var referenceOverrides: [String: String] = [:]

    func applyReferenceCorrection(id: String, bibtex: String) {
        referenceOverrides[id] = bibtex
        if citations[id] != nil, let corrected = AuthorCitation(bibtexString: bibtex, identifier: id) {
            citations[id] = corrected
        }
        hasUnsavedChanges = true
    }
    var createdText: String { original.created.formatted(date: .long, time: .shortened) }

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

    /// The draft as it would be saved right now: the text's paragraphs,
    /// tables, images and citations, under the document's fields.
    /// Existing links are preserved, and library references in the text
    /// (citations carrying an address, with or without a #fragment)
    /// become structured `cites` links.
    func buildDocument() -> LiquidDoc {
        let extracted = LiquidRichText.extract(from: textStorage)
        var body = extracted.body
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
        // Preflight edits: replace a link's or reference's BibTeX by id.
        if !referenceOverrides.isEmpty {
            links = links.map { link in
                guard let bibtex = referenceOverrides[link.to] else { return link }
                var edited = link
                edited.bibtex = bibtex
                return edited
            }
        }
        // The references: every citation the text places, in order of
        // appearance, then records the document carried that the text
        // has no citation for (so nothing is silently dropped).
        var references: [LiquidDoc.Reference] = []
        for id in extracted.citedIDs {
            if let citation = citations[id] {
                references.append(citation.reference)
            } else if let kept = original.references.first(where: { $0.id == id }) {
                references.append(kept)
            }
        }
        for reference in original.references
        where citations[reference.id] == nil && !references.contains(where: { $0.id == reference.id }) {
            references.append(reference)
        }
        references = references.map { reference in
            referenceOverrides[reference.id].map { LiquidDoc.Reference(id: reference.id, bibtex: $0) } ?? reference
        }
        var doc = LiquidDoc(format: original.format,
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
                            onBehalfOf: onBehalfOf?.trimmingCharacters(in: .whitespaces).isEmpty == false
                                ? onBehalfOf?.trimmingCharacters(in: .whitespaces) : nil,
                            documentType: original.documentType,
                            // The document's own concepts, and the
                            // library's that the text mentions.
                            concepts: documentConcepts(mentionedIn: body),
                            layouts: original.layouts,
                            mapConnections: original.mapConnections,
                            references: references,
                            tables: extracted.tables,
                            assets: extracted.assets,
                            fileURL: original.fileURL)
        doc.location = original.location
        doc.sourceURL = original.sourceURL
        doc.publication = original.publication
        doc.language = original.language
        // The front matter the document carried, then the export
        // settings over it.
        doc.subtitle = original.subtitle
        doc.journal = original.journal
        doc.doi = original.doi
        doc.isbn = original.isbn
        doc.abstract = original.abstract
        doc.keywords = original.keywords
        doc.ccsConcepts = original.ccsConcepts
        doc.license = original.license
        doc.licenseURI = original.licenseURI
        doc.authors = original.authors
        doc.affiliations = original.affiliations
        doc.authorAffiliations = original.authorAffiliations
        doc.authorEmails = original.authorEmails
        doc.authorORCIDs = original.authorORCIDs
        exportSettings.apply(to: &doc)
        return doc
    }

    /// The concepts the document carries: its own, then every library
    /// concept whose term (or another of its names) the text uses as
    /// whole words — Author's rule for what a document's glossary holds.
    /// The library's record becomes the document's copy, under the
    /// library's id, so the two stay one concept.
    private func documentConcepts(mentionedIn body: [LiquidDoc.Paragraph]) -> [LiquidDoc.Concept] {
        var result = concepts
        guard let library = conceptLibrary else { return result }
        let text = body.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return result }
        let known = Set(result.map(\.id))
        for concept in library.liveConcepts where !known.contains(concept.id) {
            let names = [concept.term] + concept.alternativeNames
            guard names.contains(where: { !$0.isEmpty && ConceptTerm.text(text, contains: $0) }) else { continue }
            if result.contains(where: { ConceptTerm.normalise($0.name) == ConceptTerm.normalise(concept.term) }) { continue }
            result.append(ConceptLibraryModel.documentConcept(from: concept))
        }
        return result
    }

    func markSaved(_ doc: LiquidDoc, package: LiquidPackage?) {
        original = doc
        if let package { self.package = package }
        hasUnsavedChanges = false
    }
}
