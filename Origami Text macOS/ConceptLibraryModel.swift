import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// The Defined Concepts library as the app holds it: where the folder is,
/// what it holds, and the acts on it — define, revise, import, flag,
/// export. Everything on disk goes through `ConceptLibraryStore`, so the
/// files stay the plain, open form any program can read.
@MainActor @Observable
final class ConceptLibraryModel {

    /// One concept as the views show it: Author's record and Origami's
    /// additions read together.
    nonisolated struct LibraryConcept: Identifiable, Hashable, Sendable {
        let record: ConceptRecord
        let extensions: ConceptExtensionRecord?

        var id: String { record.id }
        var term: String { record.headTerm }
        var definition: String { record.headDefinition }
        var kind: String? { extensions?.conceptKind ?? record.head?.tags?.first(where: { $0.lowercased() != "concept" }) }
        var sense: String? { extensions?.sense }
        var alternativeNames: [String] { (extensions?.labels ?? []).filter { $0.kind == "alt" }.map(\.value) }
        var urls: [String] { record.head?.urls ?? [] }
        var citationIDs: [String] { record.head?.citationIDs ?? [] }
        var occurrences: [ConceptExtensionRecord.Occurrence] { extensions?.occurrences ?? [] }
        /// Author's document names, for occurrences recorded by Author.
        var documentNames: [String] { record.documents }
        var relations: [ConceptExtensionRecord.Relation] { extensions?.relations ?? [] }
        var matches: [ConceptExtensionRecord.Match] { extensions?.matches ?? [] }
        var flags: Set<String> { extensions?.flags ?? [] }
        var isDeleted: Bool { record.isDeleted }
        var updated: Date { max(record.updated, extensions?.events.last?.created ?? .distantPast) }
        var versions: [ConceptEvent] { record.versions }
    }

    private(set) var concepts: [LibraryConcept] = []
    private(set) var isLoading = false
    /// Bumped on every reload, for caches keyed on the library's state.
    private(set) var revision = 0
    /// Called after every reload — the app model syncs what it mirrors.
    @ObservationIgnored var onReload: (() -> Void)?
    private(set) var lastMessage: String?
    /// The library folder in use.
    private(set) var root: URL
    private(set) var isUserChosenFolder = false

    private static let bookmarkKey = "conceptsFolderBookmark"
    private static let appName = "Origami Text"
    private var scopedFolder: URL?

    /// The device, for a readable history.
    private let device: String = {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }()

    init() {
        root = Self.defaultRoot
    }

    /// Without a chosen folder, the library lives with the app's own data.
    static var defaultRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Concepts", isDirectory: true)
    }

    /// Where Author keeps its library on this Mac, when iCloud Drive holds
    /// it: the container's root `Concepts` folder. Offered as a place to
    /// choose, never assumed — the user grants the folder.
    static var authorICloudLibraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~liquid~Author/Concepts", isDirectory: true)
    }

    private var store: ConceptLibraryStore { ConceptLibraryStore(root: root) }

    // MARK: - Location

    /// Reopens the chosen folder at launch, if there is one.
    func restore() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                adopt(url, remember: stale)
                return
            }
        }
        reload()
    }

    /// Uses a folder the user chose.
    func setFolder(_ url: URL) {
        adopt(url, remember: true)
    }

    /// Back to the app's own folder.
    func useDefaultFolder() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
        root = Self.defaultRoot
        isUserChosenFolder = false
        reload()
    }

    private func adopt(_ url: URL, remember: Bool) {
        scopedFolder?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopedFolder = url } else { scopedFolder = nil }
        if remember {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkCreationOptions = []
            #endif
            if let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            }
        }
        root = url
        isUserChosenFolder = true
        reload()
    }

    // MARK: - Loading

    func reload() {
        let store = self.store
        isLoading = true
        Task.detached(priority: .userInitiated) {
            store.resolveConflicts()
            let loaded = store.readAll()
            let concepts = loaded.records
                .map { LibraryConcept(record: $0, extensions: loaded.extensions[$0.id]) }
                .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
            await MainActor.run {
                self.concepts = concepts
                self.isLoading = false
                self.revision += 1
                self.onReload?()
            }
        }
    }

    /// A library concept as a document carries it — the document's copy,
    /// under the library's id, so the two stay one concept.
    nonisolated static func documentConcept(from concept: LibraryConcept) -> LiquidDoc.Concept {
        var copy = LiquidDoc.Concept(id: concept.id, name: concept.term)
        copy.description = concept.definition
        copy.userDefinition = concept.extensions?.definitionSource == "user" && !concept.definition.isEmpty
            ? concept.definition : nil
        copy.tag = concept.kind ?? "concept"
        copy.citationIdentifiers = concept.citationIDs
        copy.urls = concept.urls
        copy.markedForms = concept.alternativeNames
        return copy
    }

    var liveConcepts: [LibraryConcept] { concepts.filter { !$0.isDeleted } }
    var deletedConcepts: [LibraryConcept] { concepts.filter(\.isDeleted) }

    func concept(_ id: String) -> LibraryConcept? { concepts.first { $0.id == id } }

    /// The live concept holding a term, by any of its names.
    func concept(forTerm term: String) -> LibraryConcept? {
        let wanted = ConceptTerm.normalise(term)
        guard !wanted.isEmpty else { return nil }
        return liveConcepts.first { concept in
            concept.record.terms.contains(wanted)
                || concept.alternativeNames.contains { ConceptTerm.normalise($0) == wanted }
        }
    }

    // MARK: - Defining and revising

    /// A new concept, or a new version of the one holding the term.
    @discardableResult
    func define(_ draft: ConceptDraft) -> String? {
        guard draft.isPublishable else { return nil }
        let existing = draft.sourceID.flatMap { concept($0) } ?? concept(forTerm: draft.term)
        let id = existing?.id ?? draft.sourceID ?? UUID().uuidString
        do {
            let store = self.store
            store.noteLibrary(app: Self.appName)
            if let existing {
                // Same words again: a use, not a version.
                let same = ConceptTerm.normalise(existing.term) == draft.normalisedTerm
                    && existing.definition == draft.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                if same || draft.definition.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let name = draft.originDocumentName, !existing.documentNames.contains(name) {
                        try store.append(to: id) { sequence in
                            ConceptEvent(kind: .used, created: draft.date, device: device, sequence: sequence,
                                         originDocumentName: name)
                        }
                    }
                } else {
                    try store.append(to: id) { sequence in
                        ConceptEvent(kind: .version, parentID: existing.record.head?.id, created: draft.date,
                                     device: device, sequence: sequence, term: draft.term,
                                     definition: draft.definition, tags: draft.tags.isEmpty ? ["concept"] : draft.tags,
                                     urls: draft.urls, citationIDs: draft.citationIDs,
                                     originDocumentName: draft.originDocumentName)
                    }
                }
            } else {
                try store.append(to: id) { sequence in
                    ConceptEvent(kind: .version, created: draft.date, device: device, sequence: sequence,
                                 term: draft.term, definition: draft.definition,
                                 tags: draft.tags.isEmpty ? ["concept"] : draft.tags,
                                 urls: draft.urls, citationIDs: draft.citationIDs,
                                 originDocumentName: draft.originDocumentName)
                }
            }
            if let source = draft.definitionSource, existing?.extensions?.definitionSource != source {
                try store.appendExtension(to: id) { sequence in
                    var event = ConceptExtensionEvent(kind: "definitionSource", created: draft.date,
                                                      device: device, sequence: sequence)
                    event.value = source
                    return event
                }
            }
            if let documentID = draft.documentID {
                try recordOccurrence(id: id, documentID: documentID, title: draft.documentTitle, store: store,
                                     existing: existing)
            }
            return id
        } catch {
            lastMessage = "Could not write the concept: \(error.localizedDescription)"
            return nil
        }
    }

    private func recordOccurrence(id: String, documentID: String, title: String?, fragment: String? = nil,
                                  form: String? = nil, store: ConceptLibraryStore,
                                  existing: LibraryConcept?) throws {
        if existing?.occurrences.contains(where: { $0.document == documentID && $0.fragment == fragment }) == true {
            return
        }
        try store.appendExtension(to: id) { sequence in
            var event = ConceptExtensionEvent(kind: "occurrence", device: device, sequence: sequence)
            event.document = documentID
            event.title = title
            event.fragment = fragment
            event.form = form
            return event
        }
    }

    /// The user's own words for a concept.
    func setDefinition(_ id: String, term: String? = nil, definition: String) {
        guard let existing = concept(id) else { return }
        let newTerm = (term?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? existing.term
        let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newTerm != existing.term || trimmed != existing.definition else { return }
        do {
            try store.append(to: id) { sequence in
                ConceptEvent(kind: .version, parentID: existing.record.head?.id, device: device, sequence: sequence,
                             term: newTerm, definition: trimmed, tags: existing.record.head?.tags ?? ["concept"],
                             urls: existing.urls, citationIDs: existing.citationIDs)
            }
            try store.appendExtension(to: id) { sequence in
                var event = ConceptExtensionEvent(kind: "definitionSource", device: device, sequence: sequence)
                event.value = "user"
                return event
            }
            reload()
        } catch { lastMessage = error.localizedDescription }
    }

    func setKind(_ id: String, kind: String) {
        appendExtension(id, kind: "kind") { $0.value = kind.trimmingCharacters(in: .whitespaces) }
    }

    func setSense(_ id: String, sense: String) {
        appendExtension(id, kind: "sense") { $0.value = sense.trimmingCharacters(in: .whitespaces) }
    }

    func addAlternativeName(_ id: String, name: String, lang: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appendExtension(id, kind: "label") { event in
            event.value = trimmed
            event.labelKind = "alt"
            event.lang = lang
        }
    }

    func removeAlternativeName(_ id: String, name: String) {
        appendExtension(id, kind: "label") { event in
            event.value = name
            event.labelKind = "alt"
            event.on = false
        }
    }

    func addURL(_ id: String, url: String) {
        guard let existing = concept(id), !url.trimmingCharacters(in: .whitespaces).isEmpty,
              !existing.urls.contains(url) else { return }
        do {
            try store.append(to: id) { sequence in
                ConceptEvent(kind: .version, parentID: existing.record.head?.id, device: device, sequence: sequence,
                             term: existing.term, definition: existing.definition,
                             tags: existing.record.head?.tags ?? ["concept"],
                             urls: existing.urls + [url.trimmingCharacters(in: .whitespaces)],
                             citationIDs: existing.citationIDs)
            }
            reload()
        } catch { lastMessage = error.localizedDescription }
    }

    func setFlag(_ id: String, _ flag: String, on: Bool) {
        appendExtension(id, kind: "flag") { event in
            event.value = flag
            event.on = on
        }
    }

    func addRelation(_ id: String, kind: String, to target: String) {
        guard id != target else { return }
        appendExtension(id, kind: "relation") { event in
            event.relation = kind
            event.to = target
        }
    }

    func removeRelation(_ id: String, _ relation: ConceptExtensionRecord.Relation) {
        appendExtension(id, kind: "relation") { event in
            event.relation = relation.kind
            event.to = relation.to
            event.on = false
        }
    }

    func addMatch(_ id: String, scheme: String, identifier: String, url: String?, kind: String = "exact") {
        appendExtension(id, kind: "match") { event in
            event.scheme = scheme
            event.identifier = identifier
            event.url = url
            event.matchKind = kind
        }
    }

    func delete(_ id: String) { appendLifecycle(id, .deleted) }
    func restore(_ id: String) { appendLifecycle(id, .restored) }

    private func appendLifecycle(_ id: String, _ kind: ConceptEventKind) {
        do {
            try store.append(to: id) { sequence in
                ConceptEvent(kind: kind, device: device, sequence: sequence)
            }
            reload()
        } catch { lastMessage = error.localizedDescription }
    }

    private func appendExtension(_ id: String, kind: String, fill: (inout ConceptExtensionEvent) -> Void) {
        do {
            try store.appendExtension(to: id) { sequence in
                var event = ConceptExtensionEvent(kind: kind, device: device, sequence: sequence)
                fill(&event)
                return event
            }
            reload()
        } catch { lastMessage = error.localizedDescription }
    }

    // MARK: - Importing

    struct ImportReport {
        var added = 0
        var revised = 0
        var used = 0
        var skipped = 0

        var summary: String {
            var parts: [String] = []
            if added > 0 { parts.append("\(added) new") }
            if revised > 0 { parts.append("\(revised) revised") }
            if used > 0 { parts.append("\(used) already known") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.isEmpty ? "nothing to import" : parts.joined(separator: ", ")
        }
    }

    /// A document's Defined Concepts into the library: new ones defined,
    /// known ones noted as used here, every one given this document as an
    /// occurrence. Headings and other machinery are skipped.
    @discardableResult
    func importConcepts(from doc: LiquidDoc) -> ImportReport {
        var report = ImportReport()
        for concept in doc.concepts {
            var draft = ConceptDraft(term: concept.name)
            draft.definition = (concept.userDefinition?.isEmpty == false ? concept.userDefinition : concept.description) ?? ""
            draft.tags = concept.tag.map { [$0] } ?? []
            draft.urls = concept.urls
            draft.citationIDs = concept.citationIdentifiers
            draft.date = doc.listedDate
            draft.originDocumentName = doc.title
            draft.documentID = doc.id
            draft.documentTitle = doc.title
            draft.sourceID = concept.id
            draft.definitionSource = concept.userDefinition?.isEmpty == false ? "user"
                : (concept.description.isEmpty ? nil : "document")
            if concept.tag?.lowercased() == "heading" { report.skipped += 1; continue }
            guard draft.isPublishable else { report.skipped += 1; continue }
            let before = self.concept(draft.sourceID ?? "") ?? self.concept(forTerm: draft.term)
            guard let id = define(draft) else { report.skipped += 1; continue }
            if before == nil { report.added += 1 }
            else if store.record(id)?.head?.id != before?.record.head?.id { report.revised += 1 }
            else { report.used += 1 }
            // Other names the glossary marked for the concept.
            for form in concept.markedForms where ConceptTerm.normalise(form) != draft.normalisedTerm {
                if !(before?.alternativeNames.contains { ConceptTerm.normalise($0) == ConceptTerm.normalise(form) } ?? false) {
                    _ = try? store.appendExtension(to: id) { sequence in
                        var event = ConceptExtensionEvent(kind: "label", device: device, sequence: sequence)
                        event.value = form
                        event.labelKind = "alt"
                        return event
                    }
                }
            }
        }
        reload()
        return report
    }

    /// Every document in the library that carries concepts.
    @discardableResult
    func importConcepts(from docs: [LiquidDoc]) -> ImportReport {
        var total = ImportReport()
        for doc in docs where !doc.concepts.isEmpty {
            let report = importConcepts(from: doc)
            total.added += report.added
            total.revised += report.revised
            total.used += report.used
            total.skipped += report.skipped
        }
        return total
    }

    /// An Author document's glossary.
    @discardableResult
    func importAuthorDocument(at url: URL) -> ImportReport {
        var report = ImportReport()
        guard let drafts = AuthorGlossaryReader.drafts(inDocumentAt: url) else { return report }
        for draft in drafts {
            guard draft.isPublishable else { report.skipped += 1; continue }
            let before = concept(forTerm: draft.term)
            guard let id = define(draft) else { report.skipped += 1; continue }
            if before == nil { report.added += 1 } else { report.used += 1 }
            _ = id
        }
        reload()
        return report
    }

    /// Another library folder — Author's iCloud library, a colleague's
    /// export, a conflicted copy — merged into this one by event union.
    @discardableResult
    func importLibrary(at folder: URL) -> ImportReport {
        var report = ImportReport()
        let other = ConceptLibraryStore(root: folder)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let loaded = other.readAll()
        let known = Set(concepts.map(\.id))
        store.noteLibrary(app: Self.appName)
        for record in loaded.records {
            do {
                try store.write(record)
                if known.contains(record.id) { report.used += 1 } else { report.added += 1 }
            } catch { report.skipped += 1 }
        }
        for (_, extensionRecord) in loaded.extensions {
            try? store.write(extensionRecord)
        }
        reload()
        return report
    }

    // MARK: - Export

    func skosData() -> Data? {
        ConceptLibrarySKOS.jsonLD(records: concepts.map(\.record),
                                  extensions: Dictionary(uniqueKeysWithValues: concepts.compactMap { concept in
                                      concept.extensions.map { (concept.id, $0) }
                                  }))
    }

    func clearMessage() { lastMessage = nil }
}
