import SwiftUI

/// Trailing inspector (⌥⌘L): outgoing links and backlinks for the current document.
struct LinksInspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            // A library book in the reader: its declared relationships and
            // where the library cites it. Otherwise the community-folder
            // document the panel has always shown.
            if let book = model.openEPUB,
               let record = model.epubRecords.first(where: { $0.folder == book.id }) {
                BookLinksList(book: book, record: record)
            } else if let doc = model.current?.doc {
                LinksList(doc: doc)
            } else {
                ContentUnavailableView("No Document", systemImage: "link")
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 270)
    }
}

private struct LinksList: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        List {
            Section("Links from This Document") {
                if doc.links.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(doc.links.enumerated()), id: \.offset) { _, link in
                    OutgoingLinkRow(link: link, sourceDoc: doc)
                }
            }
            Section("Backlinks") {
                let refs = model.index.backlinks[doc.id] ?? []
                if refs.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                    BacklinkRow(ref: ref)
                }
            }
        }
    }
}

private struct OutgoingLinkRow: View {
    @Environment(AppModel.self) private var model
    let link: LiquidDoc.Link
    let sourceDoc: LiquidDoc
    @State private var showUnresolvedPopover = false

    var body: some View {
        let resolved = model.resolve(target: link.to, rel: link.rel)
        Button {
            if resolved == nil {
                showUnresolvedPopover = true
            }
            model.follow(link, from: sourceDoc)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let resolved {
                    Text(resolved.doc.title)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 5) {
                        Text(link.to)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("unresolved")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                detailLine
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showUnresolvedPopover) {
            Text("This document is not in the community folder yet.")
                .padding(12)
        }
    }

    @ViewBuilder private var detailLine: some View {
        HStack(spacing: 6) {
            if let rel = link.rel {
                Text(rel)
            }
            if let fragment = link.fragment {
                Text("→ ¶\(fragment)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct BacklinkRow: View {
    @Environment(AppModel.self) private var model
    let ref: BacklinkRef

    var body: some View {
        if let entry = model.index.byID[ref.fromID] {
            Button {
                model.open(entry.doc)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.doc.title)
                        .lineLimit(2)
                    if let rel = ref.rel {
                        Text(rel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The Links panel for a library book: the relationships it declares to
/// other works (§9.6, typed links, editions), the books it links to, and
/// the places in the library that cite it.
private struct BookLinksList: View {
    @Environment(AppModel.self) private var model
    let book: OpenEPUB
    let record: EPUBRecord

    var body: some View {
        let doc = model.readingDoc(forBook: book)
        let relationships = model.declaredRelationships(for: record, doc: doc)
        let outgoing = (doc?.links ?? []).filter { ($0.rel ?? "cites") == "cites" }
        let cited = citingDocuments
        List {
            Section("Relationships") {
                if relationships.isEmpty {
                    Text("This book declares none.").foregroundStyle(.secondary)
                }
                ForEach(relationships) { relationship in
                    RelationshipRow(relationship: relationship)
                }
            }
            Section("Links from This Book") {
                if outgoing.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(Array(outgoing.enumerated()), id: \.offset) { _, link in
                    RelationshipRow(relationship: DeclaredRelationship(
                        rel: "cites", target: link.to, targetAddress: link.fragment,
                        fromAddress: nil, quotedText: link.span))
                }
            }
            Section("Cited in Your Library") {
                if cited.isEmpty {
                    Text("Nothing in your library cites this book yet.").foregroundStyle(.secondary)
                }
                ForEach(cited, id: \.docID) { entry in
                    Button {
                        if let first = entry.places.first {
                            model.openCitedHere(first)
                        } else {
                            model.openEPUB(address: entry.docID, fragment: nil)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).lineLimit(2)
                            Text(entry.places.isEmpty ? "cites the book"
                                 : entry.places.count == 1 ? "cites 1 passage"
                                 : "cites \(entry.places.count) passages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Every document citing this book: its passage-level citations, and
    /// whole-book citations from the backlink index.
    private var citingDocuments: [(docID: String, title: String, places: [CitedHere])] {
        var places: [String: [CitedHere]] = [:]
        var titles: [String: String] = [:]
        for cited in model.citedHere(inBook: record).values.flatMap({ $0 }) {
            places[cited.citingDocID, default: []].append(cited)
            titles[cited.citingDocID] = cited.citingTitle
        }
        let identities = [record.id, record.packageIdentifier, record.doi].compactMap { $0 }
        for identity in identities {
            for ref in model.index.backlinks[identity] ?? [] where ref.fromID != record.id {
                if places[ref.fromID] == nil { places[ref.fromID] = [] }
                if titles[ref.fromID] == nil {
                    titles[ref.fromID] = model.index.byID[ref.fromID]?.doc.title ?? ref.fromID
                }
            }
        }
        return places.map { (docID: $0.key, title: titles[$0.key] ?? $0.key, places: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// One declared relationship: its kind, the other work (a library book
/// opens at the passage named; anything else says it is not here), and
/// the quoted words when the link carries them.
private struct RelationshipRow: View {
    @Environment(AppModel.self) private var model
    let relationship: DeclaredRelationship

    var body: some View {
        let target = model.libraryRecord(forIdentity: relationship.target)
        Button {
            if let target {
                model.openEPUB(address: target.id, fragment: relationship.targetAddress)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if let target {
                    Text(target.title).lineLimit(2)
                } else {
                    HStack(spacing: 5) {
                        Text(relationship.target)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("not in your library")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let quoted = relationship.quotedText, !quoted.isEmpty {
                    Text("\u{201C}\(quoted)\u{201D}")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
    }

    /// "Supporting", "Retracting"… for the discourse relations; the
    /// record's own word otherwise.
    private var label: String {
        if let relation = DocumentRelation.from(rel: relationship.rel),
           let byline = relation.bylineLabel { return byline }
        switch relationship.rel {
        case "cites": return "Cites"
        case "transcludes": return "Quotes (transcludes)"
        case "replaces": return "Replaces the edition"
        case "is replaced by": return "Replaced by the edition"
        default: return relationship.rel.capitalized
        }
    }
}
