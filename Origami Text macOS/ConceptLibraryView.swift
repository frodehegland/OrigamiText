#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Define Concept… — the selected words as a Defined Concept, in the
/// reader's own words. Known already: the library's definition is here
/// to revise. New: a fresh concept. Either way this document is noted as
/// a place the concept appears; a draft being written takes the concept
/// into its own glossary too.
struct DefineConceptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let term: String
    let doc: LiquidDoc?
    @State private var editedTerm = ""
    @State private var definition = ""
    @State private var kind = ""

    private var existing: ConceptLibraryModel.LibraryConcept? { model.conceptLibrary.concept(forTerm: term) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing == nil ? "Define Concept" : "Revise Concept")
                .font(.headline)
            TextField("Term", text: $editedTerm)
                .textFieldStyle(.roundedBorder)
            TextField("Kind — concept, person, institution, place, work (optional)", text: $kind)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $definition)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            if let existing {
                Text("Already in your library\(existing.occurrences.isEmpty ? "" : ", in \(existing.occurrences.count) document\(existing.occurrences.count == 1 ? "" : "s")"). Saving adds a new version; the old one stays in its history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let doc {
                Text("“\(doc.title)” is noted as a place this concept appears\(model.draftEditor?.docID == doc.id ? ", and the draft takes the concept into its glossary" : "").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Define" : "Save") {
                    model.defineConcept(term: editedTerm.trimmingCharacters(in: .whitespaces),
                                        definition: definition, kind: kind, in: doc)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(editedTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            editedTerm = existing?.term ?? term
            definition = existing?.definition ?? ""
            kind = existing?.kind ?? ""
        }
    }
}

/// Views ▸ Defined Concepts: the library of concepts shared with Author —
/// every concept the reader has defined or imported, where each appears,
/// and the acts on it. The files behind it are plain JSON in a folder
/// (Settings ▸ Concepts), so the same library serves Author on every
/// device and any other program that reads the format.
struct ConceptLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    @State private var filter = ""
    @State private var showingNew = false
    @State private var showDeleted = false

    private var library: ConceptLibraryModel { model.conceptLibrary }

    private var shown: [ConceptLibraryModel.LibraryConcept] {
        let base = showDeleted ? library.deletedConcepts : library.liveConcepts
        let wanted = ConceptTerm.normalise(filter)
        guard !wanted.isEmpty else { return base }
        return base.filter { concept in
            ConceptTerm.normalise(concept.term).contains(wanted)
                || concept.alternativeNames.contains { ConceptTerm.normalise($0).contains(wanted) }
                || ConceptTerm.normalise(concept.definition).contains(wanted)
        }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Defined Concepts")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingNew = true
                } label: {
                    Label("New Concept", systemImage: "plus")
                }
                .help("Define a concept in your own words")
                Menu {
                    Button("From the Library's Books") {
                        let report = library.importConcepts(from: model.index.byID.values.map(\.doc))
                        model.showNote("Concepts from the library: \(report.summary)")
                    }
                    Button("From an Author Document…") { importAuthorDocument() }
                    Button("From Another Concept Library…") { importLibraryFolder() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Bring Defined Concepts in — from every book here, from an Author document's glossary, or from another library folder (Author's iCloud library, a colleague's export)")
                Button {
                    exportSKOS()
                } label: {
                    Label("Export SKOS…", systemImage: "square.and.arrow.up")
                }
                .help("The library as a SKOS concept scheme in JSON-LD — for any other vocabulary tool")
                Button {
                    library.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Read the folder again — after a sync, or after Author wrote to it")
            }
        }
        .sheet(isPresented: $showingNew) {
            NewConceptSheet { term, definition, kind in
                var draft = ConceptDraft(term: term)
                draft.definition = definition
                draft.tags = kind.isEmpty ? [] : [kind]
                draft.definitionSource = "user"
                if let id = library.define(draft) {
                    library.reload()
                    selectedID = id
                }
            }
        }
        .onAppear {
            if library.concepts.isEmpty { library.reload() }
        }
        .onChange(of: library.lastMessage) { _, message in
            if let message {
                model.showNote(message)
                library.clearMessage()
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a concept", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()
            List(selection: $selectedID) {
                ForEach(shown) { concept in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(concept.term.isEmpty ? "Untitled" : concept.term)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if concept.flags.contains("tracked") {
                                Image(systemName: "lightbulb.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let kind = concept.kind, kind.lowercased() != "concept" {
                                Text(kind)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !concept.definition.isEmpty {
                            Text(concept.definition)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(concept.id)
                }
            }
            .overlay {
                if shown.isEmpty {
                    if library.isLoading {
                        ProgressView()
                    } else if library.concepts.isEmpty {
                        ContentUnavailableView {
                            Label("No Defined Concepts Yet", systemImage: "character.book.closed")
                        } description: {
                            Text("Define one with New Concept, or Import them — from the library's books, from an Author document, or from Author's own concept library folder.")
                        }
                    } else {
                        ContentUnavailableView.search(text: filter)
                    }
                }
            }
            Divider()
            HStack {
                Text("\(library.liveConcepts.count) concepts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !library.deletedConcepts.isEmpty {
                    Toggle("Deleted", isOn: $showDeleted)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let concept = library.concept(id) {
            ConceptDetailView(concept: concept)
                .id(id)
        } else {
            ContentUnavailableView {
                Label("Defined Concepts", systemImage: "character.book.closed")
            } description: {
                Text("Select a concept to read and revise its definition, see where it appears, and link it to others. The library is a folder of plain JSON files: Settings ▸ Concepts.")
            }
        }
    }

    // MARK: Import and export

    private func importAuthorDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose Author documents (.liquid); their Defined Concepts join the library."
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        var total = ConceptLibraryModel.ImportReport()
        for url in panel.urls where url.pathExtension.lowercased() == "liquid" {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let report = library.importAuthorDocument(at: url)
            total.added += report.added
            total.used += report.used
            total.skipped += report.skipped
        }
        model.showNote("Concepts from Author: \(total.summary)")
    }

    private func importLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ConceptLibraryModel.authorICloudLibraryURL
        panel.message = "Choose a concept library folder — Author's own (iCloud Drive ▸ Author ▸ Concepts), or any folder in this format. Its concepts merge into yours; nothing is overwritten."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = library.importLibrary(at: url)
        model.showNote("Concept library merged: \(report.summary)")
    }

    private func exportSKOS() {
        guard let data = library.skosData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "Defined Concepts.jsonld"
        panel.message = "The library as a SKOS concept scheme (JSON-LD)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            model.showNote("Exported \(library.liveConcepts.count) concepts as SKOS")
        } catch {
            model.showNote("Export failed: \(error.localizedDescription)")
        }
    }
}

/// One concept: its words, where it appears, what it is linked to, and
/// its history. Every change is an event appended to the library.
private struct ConceptDetailView: View {
    @Environment(AppModel.self) private var model
    let concept: ConceptLibraryModel.LibraryConcept
    @State private var term = ""
    @State private var definition = ""
    @State private var kind = ""
    @State private var sense = ""
    @State private var newName = ""
    @State private var newURL = ""
    @State private var relationTarget = ""
    @State private var relationKind = "related"
    @State private var matchScheme = "wikidata"
    @State private var matchIdentifier = ""

    private var library: ConceptLibraryModel { model.conceptLibrary }

    private var hasEdits: Bool {
        term.trimmingCharacters(in: .whitespaces) != concept.term
            || definition.trimmingCharacters(in: .whitespacesAndNewlines) != concept.definition
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The words.
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Term", text: $term)
                        .textFieldStyle(.plain)
                        .font(AppFonts.heading(24))
                    if let source = concept.extensions?.definitionSource {
                        Text(sourceLabel(source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextEditor(text: $definition)
                        .font(AppFonts.body(15))
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    HStack {
                        Toggle("Tracked", isOn: Binding(
                            get: { concept.flags.contains("tracked") },
                            set: { library.setFlag(concept.id, "tracked", on: $0) }))
                            .toggleStyle(.checkbox)
                            .help("A tracked concept is one you are following across the library")
                        Spacer()
                        if concept.isDeleted {
                            Button("Restore") { library.restore(concept.id) }
                        } else {
                            Button("Delete") { library.delete(concept.id) }
                                .help("Hidden from the library, recoverable under Deleted")
                        }
                        Button("Save Definition") {
                            library.setDefinition(concept.id, term: term, definition: definition)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasEdits)
                    }
                }

                section("Kind and sense") {
                    HStack {
                        TextField("Kind (concept, person, institution, place, work…)", text: $kind)
                            .onSubmit { library.setKind(concept.id, kind: kind) }
                        TextField("Sense — which meaning (\u{201C}model (statistics)\u{201D})", text: $sense)
                            .onSubmit { library.setSense(concept.id, sense: sense) }
                    }
                    .textFieldStyle(.roundedBorder)
                }

                section("Other names") {
                    WrappingHStack(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(concept.alternativeNames, id: \.self) { name in
                            HStack(spacing: 3) {
                                Text(name)
                                Button {
                                    library.removeAlternativeName(concept.id, name: name)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 7))
                                }
                                .buttonStyle(.plain)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        }
                        TextField("Add a name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit {
                                library.addAlternativeName(concept.id, name: newName)
                                newName = ""
                            }
                    }
                }

                section("Appears in") {
                    if concept.occurrences.isEmpty && concept.documentNames.isEmpty {
                        Text("No documents yet. Import brings a concept's documents with it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(concept.occurrences, id: \.self) { occurrence in
                        HStack {
                            Text(occurrence.title ?? occurrence.document)
                                .lineLimit(1)
                            Spacer()
                            Button("Open") { open(documentID: occurrence.document) }
                                .controlSize(.small)
                        }
                    }
                    ForEach(concept.documentNames.filter { name in
                        !concept.occurrences.contains { $0.title == name }
                    }, id: \.self) { name in
                        HStack {
                            Text(name).lineLimit(1)
                            Spacer()
                            Text("Author")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                section("Related concepts") {
                    ForEach(concept.relations, id: \.self) { relation in
                        HStack {
                            Text(relation.kind).foregroundStyle(.secondary)
                            Text(library.concept(relation.to)?.term ?? relation.to)
                            Spacer()
                            Button {
                                library.removeRelation(concept.id, relation)
                            } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Picker("", selection: $relationKind) {
                            ForEach(["related", "broader", "narrower", "partOf", "opposes"], id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Picker("", selection: $relationTarget) {
                            Text("Choose a concept").tag("")
                            ForEach(library.liveConcepts.filter { $0.id != concept.id }) { other in
                                Text(other.term).tag(other.id)
                            }
                        }
                        .labelsHidden()
                        Button("Link") {
                            guard !relationTarget.isEmpty else { return }
                            library.addRelation(concept.id, kind: relationKind, to: relationTarget)
                            relationTarget = ""
                        }
                        .disabled(relationTarget.isEmpty)
                    }
                }

                section("Matches elsewhere") {
                    ForEach(concept.matches, id: \.self) { match in
                        HStack {
                            Text("\(match.scheme): \(match.identifier)")
                            if let url = match.url, let link = URL(string: url) {
                                Link("Open", destination: link).font(.caption)
                            }
                            Spacer()
                            Text(match.kind).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Picker("", selection: $matchScheme) {
                            ForEach(["wikidata", "ccs", "orcid", "doi", "url"], id: \.self) { Text($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        TextField("Identifier (Q42, 10.1145/…, https://…)", text: $matchIdentifier)
                            .textFieldStyle(.roundedBorder)
                        Button("Match") {
                            let identifier = matchIdentifier.trimmingCharacters(in: .whitespaces)
                            guard !identifier.isEmpty else { return }
                            library.addMatch(concept.id, scheme: matchScheme, identifier: identifier,
                                             url: matchURL(scheme: matchScheme, identifier: identifier))
                            matchIdentifier = ""
                        }
                        .disabled(matchIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("A match says this concept is the same as one in another vocabulary — it never merges the two.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("Links") {
                    ForEach(concept.urls, id: \.self) { url in
                        if let link = URL(string: url) {
                            Link(url, destination: link).lineLimit(1)
                        } else {
                            Text(url).lineLimit(1)
                        }
                    }
                    HStack {
                        TextField("https://", text: $newURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            library.addURL(concept.id, url: newURL)
                            newURL = ""
                        }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                section("History") {
                    ForEach(concept.versions.reversed()) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(version.term ?? "")
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(version.created.formatted(date: .abbreviated, time: .shortened)) · \(version.device)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let definition = version.definition, !definition.isEmpty {
                                Text(definition)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            if let origin = version.originDocumentName, !origin.isEmpty {
                                Text("from \(origin)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text("Concept id \(concept.id)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear(perform: seed)
        .onChange(of: concept) { _, _ in seed() }
    }

    private func seed() {
        term = concept.term
        definition = concept.definition
        kind = concept.kind ?? ""
        sense = concept.sense ?? ""
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "user": "Defined in your own words"
        case "document": "Defined in a document"
        case "ai": "Described by a model — review before trusting"
        default: source
        }
    }

    private func matchURL(scheme: String, identifier: String) -> String? {
        switch scheme {
        case "wikidata": "https://www.wikidata.org/wiki/\(identifier)"
        case "orcid": "https://orcid.org/\(identifier)"
        case "doi": "https://doi.org/\(identifier)"
        case "url": identifier
        default: nil
        }
    }

    /// A document named by its stable id: the library's copy when it is
    /// here, else the shelf's.
    private func open(documentID: String) {
        if let entry = model.index.byID[LiquidAddress.canonical(documentID)] ?? model.index.byID[documentID] {
            model.openInLibrary(entry.doc)
        } else {
            model.openEPUBRecord(withID: documentID)
        }
    }
}

/// New Concept: a term and its definition in the reader's own words.
private struct NewConceptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDefine: (String, String, String) -> Void
    @State private var term = ""
    @State private var definition = ""
    @State private var kind = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Concept").font(.headline)
            TextField("Term", text: $term)
                .textFieldStyle(.roundedBorder)
            TextField("Kind — concept, person, institution, place, work (optional)", text: $kind)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $definition)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Define") {
                    onDefine(term, definition, kind)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

/// Settings ▸ Concepts: where the library lives. A folder of plain JSON
/// files; put it in a synced folder and every device and app shares it.
struct ConceptsSettingsView: View {
    @Environment(AppModel.self) private var model
    private var library: ConceptLibraryModel { model.conceptLibrary }

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    Text(library.root.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Concepts") {
                    Text("\(library.liveConcepts.count) live, \(library.deletedConcepts.count) deleted")
                }
                HStack {
                    Button("Choose Folder…") { chooseFolder(startingAt: nil) }
                    Button("Use Author's iCloud Library…") {
                        chooseFolder(startingAt: ConceptLibraryModel.authorICloudLibraryURL)
                    }
                    .help("Author keeps its Defined Concepts in iCloud Drive ▸ Author ▸ Concepts; choose that folder and both apps share one library on every device")
                    if library.isUserChosenFolder {
                        Button("Use the App's Own Folder") { library.useDefaultFolder() }
                    }
                    Spacer()
                    Button("Reload") { library.reload() }
                }
            } header: {
                Text("Defined Concepts")
            } footer: {
                Text("The library is a folder of plain JSON files — one file per concept, each an append-only log of its definitions and uses, in the format Author writes (see ORIGAMI-CONCEPTS-FORMAT.md). Nothing proprietary: any program can read or write it, and any synced folder (iCloud Drive, Dropbox, git) shares it between devices. Two copies of a concept always merge; nothing is lost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func chooseFolder(startingAt start: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.message = "Choose the folder that holds your Defined Concepts library — a synced folder shares it with your other devices and with Author."
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.setFolder(url)
    }
}

#endif
