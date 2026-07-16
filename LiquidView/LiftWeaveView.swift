import SwiftUI

/// The Lift Weave: the Weave's figure for lifted words. Every knot is a
/// person's contribution — an extract (a statement lifted out of a
/// transcript into a letter of its own) or a transcript — grouped around
/// the wheel by whose words they are, and every thread runs from an
/// extract back to the transcript it was lifted from. The same canvas as
/// the Weave: hover to flare, drag to spin, click to read.
struct LiftWeaveView: View {
    @Environment(AppModel.self) private var model

    /// An extract is a document declared `extract`, or — lifted before the
    /// type existed — one carrying someone's words with a statement-scoped
    /// citation back to its source.
    static func isExtract(_ doc: LiquidDoc) -> Bool {
        if doc.documentType == LiquidDoc.DocumentType.extract.rawValue { return true }
        return doc.onBehalfOf != nil
            && doc.links.contains { $0.rel == DocumentRelation.cites.rawValue && $0.fragment != nil }
    }

    var body: some View {
        let woven = build()
        if woven.data.nodes.isEmpty {
            ContentUnavailableView(
                "Nothing Lifted Yet",
                systemImage: "quote.opening",
                description: Text("Lift a statement out of a transcript (click a speaker's name) and the thread from the extract back to its transcript appears here.")
            )
        } else {
            WeaveCanvas(data: woven.data,
                        onOpen: { open(id: $0) },
                        title: "The Lift Weave",
                        subtitle: "\(woven.extracts) extracts · \(woven.transcripts) transcripts")
        }
    }

    /// Library and published copies together, deduplicated — extracts
    /// usually live in Published before they reach the community folder.
    private func allDocs() -> [LiquidDoc] {
        var seen: Set<String> = []
        var docs: [LiquidDoc] = []
        for doc in model.index.byID.values.map(\.doc) + model.drafts.published
        where seen.insert(doc.id).inserted {
            docs.append(doc)
        }
        return docs
    }

    private func build() -> (data: WeaveData, extracts: Int, transcripts: Int) {
        let docs = allDocs()
        let byID = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let extracts = docs.filter(Self.isExtract)

        // Each extract's way back: its citation, followed through revision
        // chains to the transcript's latest form.
        var sourceOf: [String: String] = [:]
        for extract in extracts {
            guard let link = extract.links.first(where: { $0.rel == DocumentRelation.cites.rawValue })
            else { continue }
            let sourceID = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
            if byID[sourceID] != nil { sourceOf[extract.id] = sourceID }
        }
        let transcripts = Set(sourceOf.values).compactMap { byID[$0] }

        // Everyone on the wheel by whose words the knot carries: extracts
        // under their speaker, transcripts under their author — the same
        // person-shaped wheel as the Weave itself.
        struct Knot {
            let doc: LiquidDoc
            let person: String
            let isTranscript: Bool
        }
        let knots = extracts.map { Knot(doc: $0, person: $0.onBehalfOf ?? $0.author, isTranscript: false) }
            + transcripts.map { Knot(doc: $0, person: $0.author, isTranscript: true) }
        let byPerson = Dictionary(grouping: knots, by: \.person)
        let people = byPerson.keys.sorted {
            (byPerson[$0]?.count ?? 0, $1) > (byPerson[$1]?.count ?? 0, $0)
        }
        var liftedFrom: [String: Int] = [:]
        for source in sourceOf.values { liftedFrom[source, default: 0] += 1 }

        var data = WeaveData()
        var indexByID: [String: Int] = [:]
        for (personIndex, person) in people.enumerated() {
            let hue = Double(personIndex) / Double(max(people.count, 1))
            let theirs = (byPerson[person] ?? []).sorted { $0.doc.created < $1.doc.created }
            let start = data.nodes.count
            for knot in theirs {
                indexByID[knot.doc.id] = data.nodes.count
                data.nodes.append(WeaveNode(id: knot.doc.id,
                                            title: knot.doc.title,
                                            author: person,
                                            weight: knot.isTranscript ? liftedFrom[knot.doc.id] ?? 0 : 0,
                                            hue: hue))
            }
            if data.nodes.count > start {
                data.authorArcs.append((person, hue, start...(data.nodes.count - 1)))
            }
        }
        for (extractID, sourceID) in sourceOf {
            guard let from = indexByID[extractID], let to = indexByID[sourceID] else { continue }
            data.edges.append(WeaveEdge(from: from, to: to))
        }
        return (data, extracts.count, transcripts.count)
    }

    private func open(id: String) {
        if let entry = model.index.byID[id] {
            model.openInLibrary(entry.doc)
        } else if let published = model.drafts.published.first(where: { $0.id == id }) {
            model.sidebarSelection = .published
            model.open(published)
        }
    }
}

extension LiftWeaveView {
    /// The Lift Weave as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "lift-weave",
        name: "The Lift Weave",
        systemImage: "quote.opening",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(LiftWeaveView()) },
        hidesDocumentList: true
    )
}
