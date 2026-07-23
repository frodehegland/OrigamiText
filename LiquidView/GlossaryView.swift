import SwiftUI

// MARK: - The personal glossary

/// One term as the reader keeps it: the word or phrase, and the gloss —
/// its meaning in the reader's own words.
nonisolated struct GlossaryTerm: Identifiable, Sendable {
    let id: String
    var term: String
    var gloss: String
}

/// The reader's personal glossary — after Jamie Blustein's personal
/// glossaries and the HAIKU group's annotation work at Dalhousie:
/// glosses in the reader's own words are how meaning is made from an
/// unfamiliar realm of discourse, and the glossary is the reader's, not
/// the text's. It lives locally, private like muting and filing — until
/// the reader chooses to publish it, whereupon it becomes an ordinary
/// document in the community folder carrying its terms in the format's
/// `concepts` field.
nonisolated enum PersonalGlossary {
    static let key = "personalGlossary"

    static func load() -> [GlossaryTerm] {
        let raw = UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
        return raw.compactMap { entry in
            guard let id = entry["id"], let term = entry["term"] else { return nil }
            return GlossaryTerm(id: id, term: term, gloss: entry["gloss"] ?? "")
        }
    }

    static func save(_ terms: [GlossaryTerm]) {
        UserDefaults.standard.set(
            terms.map { ["id": $0.id, "term": $0.term, "gloss": $0.gloss] },
            forKey: key)
    }

    /// The `documentType` a published glossary declares.
    static let documentType = "glossary"
}

// MARK: - The view

/// Glossary: the reader's own terms, glossed in their own words, and —
/// the point of the view — projected across the whole community: every
/// passage in the library that speaks the term stands under the gloss,
/// one click from being read in place. Nothing here is generated; the
/// reader makes the meaning. Terms found in documents' own concept
/// glossaries (an Author import, another reader's published glossary)
/// can be adopted rather than retyped.
struct GlossaryView: View {
    @Environment(AppModel.self) private var model
    @State private var terms: [GlossaryTerm] = []
    @State private var selectedTermID: String?
    @State private var newTerm = ""
    @State private var newGloss = ""

    private var selectedTerm: GlossaryTerm? {
        terms.first { $0.id == selectedTermID }
    }

    /// Where terms are looked for: every text document except bots,
    /// trails, and glossaries — a glossary matching itself is noise.
    private var searchableEntries: [IndexEntry] {
        model.filteredEntries
            .filter { $0.doc.body != nil }
            .filter { $0.doc.documentType != BotDocument.documentType }
            .filter { $0.doc.documentType != TrailDocument.documentType }
            .filter { $0.doc.documentType != PersonalGlossary.documentType }
    }

    var body: some View {
        HSplitView {
            termColumn
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { terms = PersonalGlossary.load() }
    }

    // MARK: The term list

    private var termColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your Glossary")
                    .font(.headline)
                Spacer()
                adoptMenu
                Button {
                    publish()
                } label: {
                    Image(systemName: "signature")
                }
                .buttonStyle(.plain)
                .disabled(terms.isEmpty)
                .help("Publish your glossary into the community folder — an ordinary document carrying your terms, for anyone to read or adopt")
            }
            .padding(10)
            Divider()
            if terms.isEmpty {
                VStack(spacing: 8) {
                    Text("A glossary is yours: terms from the community's discourse, glossed in your own words — the gloss is how the meaning becomes your own. Every passage in the library that speaks a term will stand under your gloss.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("After Jamie Blustein's personal glossaries and the HAIKU group's annotation studies at Dalhousie.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                List(selection: $selectedTermID) {
                    ForEach(terms) { term in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(term.term)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(occurrenceCount(of: term.term))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            if !term.gloss.isEmpty {
                                Text(term.gloss)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .tag(term.id)
                        .contextMenu {
                            Button("Remove Term", role: .destructive) {
                                terms.removeAll { $0.id == term.id }
                                if selectedTermID == term.id { selectedTermID = nil }
                                PersonalGlossary.save(terms)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Divider()
            addBar
        }
    }

    private var addBar: some View {
        VStack(spacing: 6) {
            TextField("Term or phrase", text: $newTerm)
                .textFieldStyle(.roundedBorder)
            TextField("Its meaning, in your own words", text: $newGloss)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTerm)
            HStack {
                Spacer()
                Button("Add to Glossary", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        let gloss = newGloss.trimmingCharacters(in: .whitespaces)
        let new = GlossaryTerm(id: UUID().uuidString.lowercased(), term: term, gloss: gloss)
        terms.append(new)
        PersonalGlossary.save(terms)
        newTerm = ""
        newGloss = ""
        selectedTermID = new.id
    }

    /// Terms already defined elsewhere in the library — a document's own
    /// concept glossary, or another reader's published glossary — offered
    /// for adoption, their glosses becoming a starting point for the
    /// reader's own.
    private var adoptMenu: some View {
        let have = Set(terms.map { $0.term.lowercased() })
        var offered: [(concept: LiquidDoc.Concept, source: String)] = []
        var seen: Set<String> = []
        for entry in model.filteredEntries {
            for concept in entry.doc.concepts {
                let key = concept.name.lowercased()
                guard !have.contains(key), seen.insert(key).inserted else { continue }
                offered.append((concept, entry.doc.title))
            }
        }
        return Menu {
            if offered.isEmpty {
                Text("No concepts found in the library's documents")
            }
            ForEach(offered, id: \.concept.id) { offer in
                Button("\(offer.concept.name) — from “\(offer.source)”") {
                    let new = GlossaryTerm(id: UUID().uuidString.lowercased(),
                                           term: offer.concept.name,
                                           gloss: offer.concept.description)
                    terms.append(new)
                    PersonalGlossary.save(terms)
                    selectedTermID = new.id
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.down.on.square")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Adopt a term another document already defines — its gloss becomes the start of yours")
    }

    // MARK: The gloss and its occurrences

    @ViewBuilder
    private var detail: some View {
        if let term = selectedTerm {
            occurrencesView(for: term)
        } else {
            ContentUnavailableView(
                "Choose a Term",
                systemImage: "character.book.closed",
                description: Text("Select a term to see your gloss and every passage in the library that speaks it — or add a term below the list."))
        }
    }

    private func occurrencesView(for term: GlossaryTerm) -> some View {
        let found = occurrences(of: term.term)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(term.term)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                TextField("Your gloss — the meaning in your own words",
                          text: glossBinding(for: term.id), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                Divider()
                if found.isEmpty {
                    Text("No passage in the library speaks this term yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Where the community speaks it")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                    ForEach(found, id: \.entry.id) { occurrence in
                        occurrenceGroup(occurrence, term: term.term)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private func glossBinding(for id: String) -> Binding<String> {
        Binding(
            get: { terms.first { $0.id == id }?.gloss ?? "" },
            set: { newValue in
                guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
                terms[index].gloss = newValue
                PersonalGlossary.save(terms)
            })
    }

    private func occurrenceGroup(_ occurrence: (entry: IndexEntry, paragraphs: [LiquidDoc.Paragraph]),
                                 term: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(occurrence.entry.doc.title) — \(occurrence.entry.doc.displayAuthor), \(occurrence.entry.doc.listedDateText)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(occurrence.paragraphs) { paragraph in
                Button {
                    model.open(occurrence.entry.doc, fragment: paragraph.id)
                } label: {
                    Text(highlighted(paragraph.displayText, term: term))
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Read it in place — the citation lands on this paragraph")
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Finding the term

    /// Whole-word, case-insensitive: "link" finds Link and links' but
    /// not blinked. Glossary Space matches with the same rule, so the
    /// two views always agree on where a term is spoken.
    nonisolated static func matcher(for term: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: term)
        return try? NSRegularExpression(pattern: "\\b\(escaped)", options: [.caseInsensitive])
    }

    private func occurrences(of term: String) -> [(entry: IndexEntry, paragraphs: [LiquidDoc.Paragraph])] {
        guard let regex = Self.matcher(for: term) else { return [] }
        var result: [(entry: IndexEntry, paragraphs: [LiquidDoc.Paragraph])] = []
        for entry in searchableEntries {
            let appendixIDs = entry.doc.visualMetaParagraphIDs
            let hits = (entry.doc.body ?? []).filter { paragraph in
                guard !appendixIDs.contains(paragraph.id) else { return false }
                let text = paragraph.displayText
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
            if !hits.isEmpty {
                result.append((entry, hits))
            }
        }
        return result.sorted { $0.entry.doc.listedDate < $1.entry.doc.listedDate }
    }

    private func occurrenceCount(of term: String) -> Int {
        guard let regex = Self.matcher(for: term) else { return 0 }
        var count = 0
        for entry in searchableEntries {
            let appendixIDs = entry.doc.visualMetaParagraphIDs
            for paragraph in (entry.doc.body ?? []) where !appendixIDs.contains(paragraph.id) {
                let text = paragraph.displayText
                count += regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            }
        }
        return count
    }

    /// The paragraph with the term lit: the reader's word, found in the
    /// community's mouth.
    private func highlighted(_ text: String, term: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let regex = Self.matcher(for: term) else { return attributed }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: attributed) else { continue }
            attributed[range].font = .system(size: 13, weight: .bold)
            attributed[range].backgroundColor = .yellow.opacity(0.3)
        }
        return attributed
    }

    // MARK: Publishing

    /// The glossary, on the record: an ordinary document — the terms as
    /// readable paragraphs for any text editor, and as `concepts` for any
    /// Origami app, so another reader can adopt them term by term.
    private func publish() {
        guard let folder = model.index.folderURL else {
            model.showNote("Choose a community folder first — the glossary would live there.")
            return
        }
        let created = Date.now
        let author = model.authorName
        let taken = Set(model.index.byID.keys)
        let id = LiquidAddress.makeID(author: author, created: created,
                                      isTaken: { taken.contains($0) })
        var paragraphs: [LiquidDoc.Paragraph] = []
        var counter = 0
        func add(_ text: String, heading: Int? = nil) {
            counter += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(counter)", heading: heading, text: text))
        }
        add("A personal glossary: terms from this community's discourse, glossed in the author's own words. Published so others can read the glosses and adopt the terms into glossaries of their own; the meanings claim no authority beyond their usefulness.")
        add("Terms", heading: 2)
        let ordered = terms.sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        for term in ordered {
            add(term.gloss.isEmpty ? term.term : "\(term.term) — \(term.gloss)")
        }
        let title = "\(author)'s Glossary"
        let slug = LiquidDoc.fileSlug(from: title)
        let ext = LiquidDoc.fileExtension
        let fileName = slug.isEmpty ? "\(id).\(ext)" : "\(slug)--\(id).\(ext)"
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title,
                            author: author,
                            created: created,
                            body: paragraphs,
                            links: [],
                            wraps: nil,
                            fileURL: folder.appendingPathComponent(fileName))
        doc.documentType = PersonalGlossary.documentType
        doc.concepts = ordered.map {
            LiquidDoc.Concept(id: $0.id, name: $0.term, description: $0.gloss)
        }
        let finished = VisualMeta.appendingAppendix(to: doc)
        do {
            try finished.jsonData().write(to: finished.fileURL, options: .atomic)
            model.showNote("“\(title)” is published — its terms can be adopted by anyone in the community.")
        } catch {
            model.showNote("Could not publish the glossary: \(error.localizedDescription)")
        }
    }
}

extension GlossaryView {
    /// The personal glossary as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "glossary",
        name: "Glossary",
        systemImage: "character.book.closed",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(GlossaryView()) },
        hidesDocumentList: true
    )
}
