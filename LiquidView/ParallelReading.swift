import Foundation

/// One visible connection between two documents shown side by side.
/// A nil paragraph ID means the beam anchors at the document's header.
nonisolated struct ParallelConnection: Identifiable, Sendable {
    enum Owner: Sendable { case left, right }
    let id: String
    let rel: String?
    let leftParagraphID: String?
    let rightParagraphID: String?
    /// Which document declares the link.
    let owner: Owner
}

/// Derivations for transpointing windows (in honor of Ted Nelson):
/// which documents connect to a given one, and the paragraph-level
/// connections between a specific pair.
nonisolated enum ParallelReading {

    /// Documents linked to or from `doc` — the candidates for parallel reading.
    static func candidates(for doc: LiquidDoc,
                           byID: [String: IndexEntry],
                           backlinks: [String: [BacklinkRef]]) -> [IndexEntry] {
        var ids: Set<String> = []
        for link in doc.links { ids.insert(link.to) }
        for ref in backlinks[doc.id] ?? [] { ids.insert(ref.fromID) }
        ids.remove(doc.id)
        return ids
            .compactMap { byID[$0] }
            .sorted { $0.doc.title.localizedCaseInsensitiveCompare($1.doc.title) == .orderedAscending }
    }

    /// All connections between the pair, both directions.
    static func connections(left: LiquidDoc, right: LiquidDoc) -> [ParallelConnection] {
        var result: [ParallelConnection] = []
        var ordinal = 0

        for link in left.links where link.to == right.id {
            ordinal += 1
            result.append(ParallelConnection(
                id: "c\(ordinal)",
                rel: link.rel,
                leftParagraphID: sourceAnchor(in: left, for: link),
                rightParagraphID: existingParagraph(link.fragment, in: right),
                owner: .left))
        }
        for link in right.links where link.to == left.id {
            ordinal += 1
            result.append(ParallelConnection(
                id: "c\(ordinal)",
                rel: link.rel,
                leftParagraphID: existingParagraph(link.fragment, in: left),
                rightParagraphID: sourceAnchor(in: right, for: link),
                owner: .right))
        }
        return result
    }

    /// If a paragraph in the source document literally mentions the target's
    /// UUID (a pasted paragraph link), the beam starts there; otherwise it
    /// starts at the document header.
    private static func sourceAnchor(in doc: LiquidDoc, for link: LiquidDoc.Link) -> String? {
        return doc.body?.first(where: { $0.text.lowercased().contains(link.to) })?.id
    }

    private static func existingParagraph(_ fragment: String?, in doc: LiquidDoc) -> String? {
        guard let fragment, doc.body?.contains(where: { $0.id == fragment }) == true else { return nil }
        return fragment
    }

    /// All connections among a set of documents shown together in space
    /// (the Connections view's open mode), paragraph-precise where possible.
    static func spaceConnections(among docs: [LiquidDoc]) -> [SpaceConnection] {
        let included = Set(docs.map(\.id))
        var result: [SpaceConnection] = []
        var ordinal = 0
        for doc in docs {
            for link in doc.links where link.to != doc.id && included.contains(link.to) {
                ordinal += 1
                let target = docs.first { $0.id == link.to }
                result.append(SpaceConnection(
                    fromDocID: doc.id,
                    fromParagraphID: sourceAnchor(in: doc, for: link),
                    toDocID: link.to,
                    toParagraphID: target.flatMap { existingParagraph(link.fragment, in: $0) },
                    rel: link.rel,
                    ordinal: ordinal))
            }
        }
        return result
    }
}

/// One paragraph-precise connection among documents laid out in space.
nonisolated struct SpaceConnection: Identifiable, Sendable {
    let fromDocID: String
    let fromParagraphID: String?
    let toDocID: String
    let toParagraphID: String?
    let rel: String?
    let ordinal: Int
    var id: String { "s\(ordinal)" }
}
