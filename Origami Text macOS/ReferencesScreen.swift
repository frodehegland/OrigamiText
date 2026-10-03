//
//  ReferencesScreen.swift
//  Origami Text
//
//  The foot bar's References: the open document's cited works as a whole
//  page — listed by title, author or date, or laid on a map where lines
//  show which of them cite each other. Under every entry, quiet keywords
//  tell its standing: Retracted, Expression of Concern, Corrected, In
//  Library, Open Access, how often cited (ReferenceStatus.swift). A whole-
//  page reading like Overview: `AppModel.readingReferencesOn`, the foot
//  stays, any word there is the way back.
//

import SwiftUI
import AppKit

/// One cited work as the References page reads it.
struct ReferenceEntry: Identifiable {
    /// The citation card's key — the reference id, or a library link's
    /// address for an internal citation.
    let id: String
    let record: BibTeXRecord?
    let title: String
    let authors: String
    /// The first author's family name, folded — the Author listing's order.
    let familyKey: String
    let year: Int?
    let venue: String
    let doi: String?
    /// The citation graph's node key — the same one the card and the
    /// Maps use, so all three share one cache.
    let graphKey: String
    let graphTitle: String
    let graphAuthor: String
    /// The shelf book this work is, when it is on the shelf.
    let libraryID: String?
    /// The BibTeX entry type — "article", "book", "misc"…
    let entryType: String
    /// Shares an author with the paper citing it.
    let isSelf: Bool
}

struct ReferencesScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let book: OpenEPUB

    enum Listing: String, CaseIterable, Identifiable {
        case title, author, date, map
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: "Title"
            case .author: "Author"
            case .date: "Date"
            case .map: "Map"
            }
        }
    }

    @AppStorage("referencesListing") private var listingRaw = Listing.title.rawValue
    private var listing: Listing { Listing(rawValue: listingRaw) ?? .title }

    @State private var doc: LiquidDoc?
    @State private var entries: [ReferenceEntry] = []
    @State private var loaded = false
    /// Bumped whenever a standing or a graph answer lands, so the
    /// keywords and the map's lines redraw.
    @State private var statusStamp = 0
    @State private var liveProgress: (done: Int, total: Int)?
    @State private var graphProgress: (done: Int, total: Int)?
    @State private var cardKey: CardKey?
    /// The map's lines, worked out when an answer lands — not on every
    /// redraw.
    @State private var links: [ReferencesMapView.Link] = []
    /// DOIs found for works whose BibTeX carries none (the card's
    /// lookups, the graph's own answer) — they match references too.
    @State private var foundDOIs: [String: String] = [:]
    /// How many of the paper's other references cite each one — the
    /// Foundational keyword.
    @State private var neighbourCounts: [String: Int] = [:]
    /// How often the paper's text cites each one — the Key keyword.
    @State private var textCounts: [String: Int] = [:]

    private struct CardKey: Identifiable {
        let key: String
        var id: String { key }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                Text("This document carries no reference list.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listing == .map {
                ReferencesMapView(
                    entries: entries,
                    links: links,
                    layoutKey: book.id,
                    stamp: statusStamp,
                    marks: { mapMarks(for: $0) },
                    abstractFor: { abstract(forID: $0) },
                    open: { cardKey = CardKey(key: $0.id) },
                    menu: { AnyView(entryMenu($0)) })
            } else {
                list
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: $cardKey) { card in
            if let doc {
                // A cited work that is also one of these references wears
                // an arrow in the card's "Cites" list: click, its card.
                CitationCardSheet(
                    doc: doc, key: card.key,
                    marks: entries.first { $0.id == card.key }.map(marks(for:)) ?? [],
                    siblingKey: matcher(),
                    openSibling: { cardKey = CardKey(key: $0) },
                    graphKey: entries.first { $0.id == card.key }?.graphKey)
            }
        }
        .task(id: book.id) {
            let found = model.citationCardDoc(forBook: book)
            doc = found
            entries = found.map(buildEntries) ?? []
            textCounts = found.map(Self.citationCounts) ?? [:]
            loaded = true
            recomputeLinks()
            await ReferenceStatus.loadIndexIfNeeded()
            statusStamp += 1
        }
        // The Retraction Watch subscription: a fresh copy when the one
        // held is over a week old — fetched here, never at launch.
        .task(id: book.id) {
            await ReferenceStatus.refreshIndexIfStale()
            statusStamp += 1
        }
        // The replication database, on the same beat.
        .task(id: book.id) {
            await ReferenceStatus.loadReplicationsIfNeeded()
            statusStamp += 1
            await ReferenceStatus.refreshReplicationsIfStale()
            statusStamp += 1
        }
        // The live standings, one DOI at a time, kept for a month.
        .task(id: "\(book.id)|\(loaded)") {
            guard loaded else { return }
            let pending = entries.filter { ReferenceStatus.needsLive(doi: $0.doi) }
            guard !pending.isEmpty else { return }
            liveProgress = (0, pending.count)
            for (index, entry) in pending.enumerated() {
                if Task.isCancelled { break }
                await ReferenceStatus.checkLive(doi: entry.doi)
                liveProgress = (index + 1, pending.count)
                statusStamp += 1
            }
            liveProgress = nil
        }
        // The map's lines: every cited work's OWN reference list, read
        // in full while the Map stands — from the shelf when the work is
        // there, else from every service, folded — so any two works on
        // the plane that cite each other are found. Cached thereafter.
        // Run whatever the listing: the Foundational keyword reads the
        // same lines the Map draws.
        .task(id: "\(book.id)|\(loaded)|graph") {
            guard loaded else { return }
            recomputeLinks()
            guard CitationGraph.isEnabled else { return }
            let pending = entries
                .filter { libraryReferences(for: $0) == nil
                    && !CitationGraph.isComplete(key: $0.graphKey) }
                // Works with a DOI first: their lists come surest.
                .sorted { ($0.doi != nil ? 0 : 1) < ($1.doi != nil ? 0 : 1) }
            guard !pending.isEmpty else { return }
            graphProgress = (0, pending.count)
            for (index, entry) in pending.enumerated() {
                if Task.isCancelled { break }
                // A work without a DOI is found first — the card's own
                // lookup, cached — so the services can be asked by DOI.
                var doi = entry.doi
                if doi == nil, let record = entry.record {
                    doi = ReferenceStatus.cleanDOI(await CitationLookup.enrich(record)?.doi)
                }
                let answer = await CitationGraph.completeReferences(
                    title: entry.graphTitle, author: entry.graphAuthor,
                    year: entry.year, doi: doi)
                if entry.doi == nil,
                   let found = doi ?? ReferenceStatus.cleanDOI(answer?.doi) {
                    foundDOIs[entry.id] = found
                    // A DOI found is a DOI to check.
                    if ReferenceStatus.needsLive(doi: found) {
                        await ReferenceStatus.checkLive(doi: found)
                    }
                }
                graphProgress = (index + 1, pending.count)
                recomputeLinks()
                statusStamp += 1
            }
            graphProgress = nil
        }
    }

    // MARK: The header — tabs and the standing line

    private var header: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("References")
                    .font(AppFonts.heading(20, weight: .semibold))
                if loaded {
                    Text("\(entries.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Listing", selection: $listingRaw) {
                    ForEach(Listing.allCases) { listing in
                        Text(listing.label).tag(listing.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                // Balances the title, so the tabs stand centred.
                Text("References").font(AppFonts.heading(20, weight: .semibold)).hidden()
            }
            statusLine
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var statusLine: some View {
        let _ = statusStamp
        let grave = entries.filter { entry in
            marks(for: entry).contains { $0.tone == .alarm }
        }.count
        var parts: [String] = []
        if ReferenceStatus.isRefreshingIndex {
            parts.append("Fetching the Retraction Watch database…")
        } else if let index = ReferenceStatus.retractionIndex {
            parts.append("Retraction Watch: \(index.records.formatted()) notices, updated \(index.updated.formatted(date: .abbreviated, time: .omitted))")
        } else if let error = ReferenceStatus.indexError {
            parts.append(error)
        }
        if let progress = liveProgress {
            parts.append("Checking \(progress.done) of \(progress.total) with Crossref, Unpaywall and OpenCitations")
        }
        if let progress = graphProgress {
            parts.append("Reading the cited works' own reference lists — \(progress.done) of \(progress.total)")
        } else if listing == .map {
            if !CitationGraph.isEnabled {
                parts.append("Turn on Look up cited works online in Settings to draw the links")
            } else {
                let count = links.count
                parts.append(count == 0 ? "None of these works is known to cite another"
                             : "\(count) line\(count == 1 ? "" : "s"): one work citing another")
            }
        }
        return HStack(spacing: 10) {
            if grave > 0 {
                Text(grave == 1 ? "1 cited work retracted, withdrawn or not replicated"
                     : "\(grave) cited works retracted, withdrawn or not replicated")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Text(parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: The listings

    private struct ListSection: Identifiable {
        let id: String
        let entries: [ReferenceEntry]
    }

    private var sections: [ListSection] {
        switch listing {
        case .title, .map:
            let sorted = entries.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return grouped(sorted) { Self.initial(of: Self.sortableTitle($0.title)) }
        case .author:
            let sorted = entries.sorted {
                ($0.familyKey, $0.year ?? 0) < ($1.familyKey, $1.year ?? 0)
            }
            return grouped(sorted) { Self.initial(of: $0.familyKey) }
        case .date:
            // Newest first; works without a date gather at the end.
            let sorted = entries.sorted {
                ($0.year ?? Int.min, $1.title) > ($1.year ?? Int.min, $0.title)
            }
            return grouped(sorted) { $0.year.map(String.init) ?? "No Date" }
        }
    }

    private func grouped(_ sorted: [ReferenceEntry],
                         by label: (ReferenceEntry) -> String) -> [ListSection] {
        var out: [ListSection] = []
        for entry in sorted {
            let name = label(entry)
            if let last = out.last, last.id == name {
                out[out.count - 1] = ListSection(id: name, entries: last.entries + [entry])
            } else {
                out.append(ListSection(id: name, entries: [entry]))
            }
        }
        return out
    }

    private static func sortableTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        for article in ["the ", "a ", "an "] where trimmed.lowercased().hasPrefix(article) {
            return String(trimmed.dropFirst(article.count))
        }
        return trimmed
    }

    private static func initial(of text: String) -> String {
        guard let first = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                       locale: nil).first(where: { $0.isLetter || $0.isNumber })
        else { return "#" }
        return first.isNumber ? "#" : String(first).uppercased()
    }

    private var list: some View {
        let _ = statusStamp
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            // Keyed by the listing too: the lazy stack
                            // otherwise reuses a row drawn for another
                            // listing, its colours unchanged.
                            row(entry)
                                .id(entry.id + "|" + listingRaw)
                            Divider().opacity(0.5)
                        }
                    } header: {
                        // Only Date heads its groups (the years); Title
                        // and Author run as one list, no letters.
                        if listing == .date {
                            Text(section.id)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .textBackgroundColor))
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ entry: ReferenceEntry) -> some View {
        Button {
            cardKey = CardKey(key: entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                // Sorted by author, the names read black and the title
                // steps back to grey — the same fonts either way.
                let byAuthor = listing == .author
                Text(entry.title)
                    .font(AppFonts.body(16))
                    .foregroundStyle(byAuthor ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                let byline = byline(for: entry)
                if !byline.isEmpty {
                    bylineText(for: entry, byAuthor: byAuthor)
                        .font(.callout)
                        .lineLimit(2)
                }
                let marks = marks(for: entry)
                if !marks.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(marks, id: \.self) { mark in
                            ReferenceMarkView(mark: Self.mapMark(mark), size: 11)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the citation card")
        .contextMenu { entryMenu(entry) }
    }

    /// The byline as text: in the Author listing the names alone in
    /// black, the year and venue grey as ever.
    private func bylineText(for entry: ReferenceEntry, byAuthor: Bool) -> Text {
        guard byAuthor, !entry.authors.isEmpty else {
            return Text(byline(for: entry)).foregroundStyle(.secondary)
        }
        let rest = [entry.year.map(String.init) ?? "", entry.venue]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let names = Text(entry.authors).foregroundStyle(.primary)
        return rest.isEmpty ? names
            : names + Text(" · " + rest).foregroundStyle(.secondary)
    }

    /// The listing decides what leads the byline: the authors in Author,
    /// the year in Date.
    private func byline(for entry: ReferenceEntry) -> String {
        let year = entry.year.map(String.init) ?? ""
        let parts: [String]
        switch listing {
        case .date: parts = [year, entry.authors, entry.venue]
        default: parts = [entry.authors, year, entry.venue]
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private func entryMenu(_ entry: ReferenceEntry) -> some View {
        Button("Show Citation Card") { cardKey = CardKey(key: entry.id) }
        if let libraryID = entry.libraryID {
            Button("Open in Library") { model.openEPUBRecord(withID: libraryID) }
        }
        if let url = entry.record?.webURL {
            Button("Open on the Web") { openURL(url) }
        }
        if let free = ReferenceStatus.cachedLive(doi: entry.doi)?.openAccessURL,
           let url = URL(string: free) {
            Button("Read the Free Copy") { openURL(url) }
        }
        Button("Show Citation Tree") {
            model.showCitationTree(title: entry.graphTitle, author: entry.graphAuthor,
                                   year: entry.year, doi: entry.doi)
        }
        Divider()
        Button("Copy Citation") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.record?.citationSentence ?? entry.title,
                                           forType: .string)
        }
    }

    // MARK: Standing, abstracts, links

    private func marks(for entry: ReferenceEntry) -> [ReferenceStatus.Mark] {
        let doi = entry.doi ?? foundDOIs[entry.id]
            ?? ReferenceStatus.cleanDOI(CitationGraph.cached(forKey: entry.graphKey)?.doi)
        // Unverified without a DOI: a paper-shaped entry the card's
        // lookup searched for by title and no service knew. Books and
        // web pages are often absent from the services; they never earn it.
        let paperShaped = ["article", "inproceedings", "conference"]
            .contains(entry.entryType.lowercased())
        let notFound = doi == nil && paperShaped
            && entry.record.flatMap { CitationLookup.cached(for: $0) }?.found == false
        return ReferenceStatus.marks(for: ReferenceStatus.MarkInput(
            doi: doi, title: entry.title, year: entry.year,
            inLibrary: entry.libraryID != nil,
            entryType: entry.entryType,
            fields: entry.record?.fields ?? [:],
            citedByNeighbours: neighbourCounts[entry.id] ?? 0,
            smallList: entries.count < 15,
            citedInText: textCounts[entry.id] ?? 0,
            isSelfCitation: entry.isSelf,
            notFound: notFound))
    }

    private func mapMarks(for entry: ReferenceEntry) -> [MapCardMark] {
        // A standing card keeps one quiet line: the pills, Foundational
        // and In Library; the rest waits for the list.
        marks(for: entry)
            .filter { $0.pill || $0.tone == .positive }
            .map(Self.mapMark)
    }

    static func mapMark(_ mark: ReferenceStatus.Mark) -> MapCardMark {
        let tone: MapCardMark.Tone = switch mark.tone {
        case .alarm: .alarm
        case .caution: .caution
        case .quiet: .quiet
        case .positive: .positive
        case .info: .info
        case .good: .good
        }
        return MapCardMark(text: mark.text, tone: tone, detail: mark.detail, pill: mark.pill)
    }

    /// How often the text cites each reference — its `[cite:key]` tokens.
    private static func citationCounts(in doc: LiquidDoc) -> [String: Int] {
        guard let regex = try? NSRegularExpression(pattern: #"\[cite:([^\]]+)\]"#)
        else { return [:] }
        var counts: [String: Int] = [:]
        for paragraph in doc.body ?? [] where paragraph.text.contains("[cite:") {
            let text = paragraph.text as NSString
            for match in regex.matches(in: paragraph.text,
                                       range: NSRange(location: 0, length: text.length)) {
                // One token may carry several keys: [cite:a,b].
                for key in text.substring(with: match.range(at: 1)).split(separator: ",") {
                    counts[key.trimmingCharacters(in: .whitespaces), default: 0] += 1
                }
            }
        }
        return counts
    }

    private func abstract(forID id: String) -> String {
        guard let record = entries.first(where: { $0.id == id })?.record else { return "" }
        if let own = record.fields["abstract"], !own.isEmpty {
            return CitationLookup.tidiedAbstract(own)
        }
        return CitationLookup.cached(for: record)?.abstract ?? ""
    }

    /// A cited work's reference list from the shelf, when the work is
    /// there — the most complete list there is, and no network.
    private func libraryReferences(for entry: ReferenceEntry) -> [CitationGraph.CitedRef]? {
        guard let libraryID = entry.libraryID,
              let doc = model.index.byID[libraryID]?.doc,
              !doc.references.isEmpty else { return nil }
        return doc.references.compactMap { reference in
            let record = BibTeXRecord.records(in: reference.bibtex).first
            let title = record?.title.isEmpty == false ? record?.title : reference.citedAs
            guard let title, !title.isEmpty else { return nil }
            return CitationGraph.CitedRef(
                title: title,
                authors: record?.displayAuthors ?? "",
                year: record.flatMap { Int($0.year.filter(\.isNumber).prefix(4)) },
                doi: ReferenceStatus.cleanDOI(record?.fields["doi"]))
        }
    }

    /// Which of these works cite which: each work's own references — the
    /// shelf's copy, else the citation graph — matched back onto the
    /// list. A DOI settles it; otherwise the titles must agree, allowing
    /// for a subtitle on either side and for a reference that is a whole
    /// citation string (Crossref's unstructured entries), with the years
    /// agreeing when both are known.
    private func recomputeLinks() {
        let target = matcher()
        var found: Set<ReferencesMapView.Link> = []
        for entry in entries {
            var cited: [CitationGraph.CitedRef]
            if let own = libraryReferences(for: entry) {
                cited = own
            } else if let graph = CitationGraph.cached(forKey: entry.graphKey), graph.found {
                cited = graph.references
                // The works known only by DOI (OpenCitations).
                cited += (graph.citedDOIs ?? []).map {
                    CitationGraph.CitedRef(title: "", authors: "", year: nil, doi: $0)
                }
            } else {
                continue
            }
            for reference in cited {
                if let id = target(reference), id != entry.id {
                    found.insert(ReferencesMapView.Link(from: entry.id, to: id))
                }
            }
        }
        let sorted = found.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        if sorted != links { links = sorted }
        var counts: [String: Int] = [:]
        for link in sorted { counts[link.to, default: 0] += 1 }
        if counts != neighbourCounts { neighbourCounts = counts }
    }

    /// Finds which of this paper's references a cited work is — the
    /// Map's lines and the card's arrows ask the same question.
    private func matcher() -> (CitationGraph.CitedRef) -> String? {
        var byDOI: [String: String] = [:]
        var titled: [(id: String, title: String, year: Int?)] = []
        for entry in entries {
            for doi in [entry.doi, foundDOIs[entry.id],
                        ReferenceStatus.cleanDOI(CitationGraph.cached(forKey: entry.graphKey)?.doi)]
                .compactMap({ $0 }) {
                byDOI[doi] = entry.id
            }
            let title = ReferenceStatus.normalizedTitle(entry.title)
            if title.count >= 12 { titled.append((entry.id, title, entry.year)) }
        }
        func target(of cited: CitationGraph.CitedRef) -> String? {
            if let doi = ReferenceStatus.cleanDOI(cited.doi), let id = byDOI[doi] { return id }
            let wanted = ReferenceStatus.normalizedTitle(cited.title)
            guard wanted.count >= 12 else { return nil }
            for candidate in titled {
                if let year = cited.year, let other = candidate.year, abs(year - other) > 1 {
                    continue
                }
                if wanted == candidate.title { return candidate.id }
                // A subtitle on one side, or the reference a whole
                // citation string that holds the title.
                if candidate.title.count >= 24, wanted.contains(candidate.title) {
                    return candidate.id
                }
                if wanted.count >= 24, candidate.title.contains(wanted) { return candidate.id }
            }
            return nil
        }
        return target
    }

    // MARK: Building the entries

    /// "Frode Hegland" and "Hegland, Frode" both → "hegland f": a family
    /// name and first initial, folded — enough to tell a self-citation.
    private static func authorKeys(_ names: [String]) -> Set<String> {
        var keys = Set<String>()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let family: String
            let given: String
            if let comma = name.firstIndex(of: ",") {
                family = String(name[..<comma])
                given = String(name[name.index(after: comma)...])
            } else {
                let words = name.split(separator: " ")
                family = words.last.map(String.init) ?? name
                given = words.dropLast().joined(separator: " ")
            }
            let folded = family.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                        locale: nil).trimmingCharacters(in: .whitespaces)
            let initial = given.trimmingCharacters(in: .whitespaces).first
                .map { String($0).lowercased() } ?? ""
            guard folded.count > 1 else { continue }
            keys.insert(folded + " " + initial)
        }
        return keys
    }

    private func buildEntries(from doc: LiquidDoc) -> [ReferenceEntry] {
        // The paper's own authors, as family-name-and-initial keys.
        let paperAuthors = Self.authorKeys(doc.authors.isEmpty
            ? doc.displayAuthor.components(separatedBy: ",")
            : doc.authors)
        var out: [ReferenceEntry] = []
        var seen = Set<String>()
        func add(id: String, bibtex: String, citedAs: String?) {
            let record = BibTeXRecord.records(in: bibtex).first
            let fields = record?.fields ?? [:]
            var title = record?.title ?? ""
            if title.isEmpty { title = citedAs ?? "" }
            if title.isEmpty { title = fields["note"].map(BibTeXParser.displayText) ?? "Untitled" }
            let dedupe = ReferenceStatus.normalizedTitle(title)
            guard seen.insert(dedupe.isEmpty ? id : dedupe).inserted else { return }
            let year = Int((record?.year ?? "").filter(\.isNumber).prefix(4))
            let doi = ReferenceStatus.cleanDOI(fields["doi"])
            let venue = [fields["journal"], fields["journaltitle"], fields["booktitle"], fields["publisher"]]
                .compactMap { $0 }.first.map(BibTeXParser.displayText) ?? ""
            let firstAuthor = (fields["author"] ?? fields["editor"] ?? "")
                .components(separatedBy: " and ").first ?? ""
            let family: String = {
                let name = BibTeXParser.displayText(firstAuthor)
                    .trimmingCharacters(in: .whitespaces)
                if let comma = name.firstIndex(of: ",") {
                    return String(name[..<comma])
                }
                return name.split(separator: " ").last.map(String.init) ?? name
            }()
            let graphTitle = fields["title"] ?? citedAs ?? title
            let graphAuthor = fields["author"] ?? ""
            let library = model.libraryEPUBRecord(doi: doi, datasetDOI: nil,
                                                  title: title, year: year)
            let citedAuthors = Self.authorKeys(
                (fields["author"] ?? "").components(separatedBy: " and ")
                    .map(BibTeXParser.displayText))
            out.append(ReferenceEntry(
                id: id,
                record: record,
                title: title,
                authors: record?.displayAuthors ?? "",
                familyKey: family.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                          locale: nil),
                year: year,
                venue: venue,
                doi: doi,
                graphKey: CitationGraph.key(title: graphTitle, author: graphAuthor),
                graphTitle: graphTitle,
                graphAuthor: graphAuthor,
                // The open book itself never counts as "in the library".
                libraryID: library?.id == book.id ? nil : library?.id,
                entryType: record?.entryType ?? "",
                isSelf: !citedAuthors.isDisjoint(with: paperAuthors)))
        }
        for reference in doc.references {
            add(id: reference.id, bibtex: reference.bibtex, citedAs: reference.citedAs)
        }
        // Internal citations: a library document cited through a link
        // that carries its own BibTeX — the card reads it the same way.
        for link in doc.links {
            if let bibtex = link.bibtex, !bibtex.isEmpty {
                add(id: link.to, bibtex: bibtex, citedAs: nil)
            }
        }
        return out
    }
}

// MARK: - The References map

/// The cited works on a plane, the journal Map's cards: laid out by year
/// from left to right, so a line — one work citing another — runs back
/// in time. Drag a card and it stays (kept per document on this Mac);
/// click to lift it, its own lines brighten and the unconnected step
/// back; double-click for the citation card.
struct ReferencesMapView: View {
    struct Link: Hashable {
        let from: String
        let to: String
    }

    let entries: [ReferenceEntry]
    let links: [Link]
    let layoutKey: String
    /// Redraw beat — standings and lines landing.
    let stamp: Int
    let marks: (ReferenceEntry) -> [MapCardMark]
    let abstractFor: (String) -> String
    let open: (ReferenceEntry) -> Void
    let menu: (ReferenceEntry) -> AnyView

    @State private var positions: [String: CGPoint] = [:]
    @State private var liftedID: String?
    @State private var liveDrag = MapLiveDrag()
    @State private var yearCaptions: [(label: String, x: CGFloat)] = []

    /// The plane's least size; it grows to hold every card, so a long
    /// column of one year's works scrolls rather than falling off.
    private static let baseSize = CGSize(width: 2400, height: 1500)

    private var canvasSize: CGSize {
        let maxX = positions.values.map(\.x).max() ?? 0
        let maxY = positions.values.map(\.y).max() ?? 0
        return CGSize(width: max(Self.baseSize.width, maxX + 260),
                      height: max(Self.baseSize.height, maxY + 200))
    }
    private static let margin: CGFloat = 160
    private static let columnWidth: CGFloat = 185
    private static let rowHeight: CGFloat = 50
    private static let top: CGFloat = 150

    private var storeKey: String { "referencesMap:" + layoutKey }

    var body: some View {
        let _ = stamp
        let connected = connectedIDs
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                // The empty plane: a click there sets the lifted card down.
                Color.clear
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { liftedID = nil }
                ForEach(yearCaptions.indices, id: \.self) { index in
                    Text(yearCaptions[index].label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .position(x: yearCaptions[index].x, y: Self.top - 60)
                        .allowsHitTesting(false)
                }
                // The lines beneath every card; the card in hand redraws
                // them each frame, nothing else does.
                MapLiveThreads(liveDrag: liveDrag) { context, _, live in
                    drawLinks(in: &context, live: live)
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .allowsHitTesting(false)
                ForEach(entries) { entry in
                    ProceedingsMapNode(
                        item: ProceedingsMapView.Item(
                            id: entry.id, key: entry.id, title: entry.title,
                            author: [entry.authors, entry.year.map(String.init) ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · ")),
                        emphasis: connected.map { $0.contains(entry.id) } ?? true
                            ? .normal : .dimmed,
                        isLifted: liftedID == entry.id,
                        position: binding(for: entry),
                        // A card may be dragged a screen beyond the
                        // last one; the plane grows to follow it.
                        bounds: CGSize(width: canvasSize.width + 400,
                                       height: canvasSize.height + 400),
                        open: { open(entry) },
                        abstractFor: abstractFor,
                        select: { liftedID = liftedID == entry.id ? nil : entry.id },
                        togglePin: {},
                        toggleSetAside: {},
                        moved: { save() },
                        liveMoved: { point in
                            liveDrag.id = point == nil ? nil : entry.id
                            if let point { liveDrag.point = point }
                        },
                        marks: marks(entry),
                        menu: { menu(entry) })
                    .zIndex(liftedID == entry.id ? 1 : 0)
                }
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color.secondary.opacity(0.06))
        .onAppear(perform: load)
        .onChange(of: entries.map(\.id)) { load() }
    }

    /// While a card is lifted, the works joined to it by a line.
    private var connectedIDs: Set<String>? {
        guard let liftedID else { return nil }
        var ids: Set<String> = [liftedID]
        for link in links where link.from == liftedID || link.to == liftedID {
            ids.insert(link.from)
            ids.insert(link.to)
        }
        return ids
    }

    private func drawLinks(in context: inout GraphicsContext,
                           live: (String) -> CGPoint?) {
        for link in links {
            guard let start = live(link.from) ?? positions[link.from],
                  let end = live(link.to) ?? positions[link.to] else { continue }
            let touchesLifted = liftedID != nil
                && (link.from == liftedID || link.to == liftedID)
            let quiet = liftedID != nil && !touchesLifted
            let color = Color.accentColor.opacity(quiet ? 0.08 : touchesLifted ? 0.85 : 0.35)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), lineWidth: touchesLifted ? 2 : 1.2)
            // The arrowhead stops short of the cited card's centre, so it
            // shows beside the card rather than under it.
            let dx = end.x - start.x, dy = end.y - start.y
            let length = max(sqrt(dx * dx + dy * dy), 1)
            let ux = dx / length, uy = dy / length
            let inset: CGFloat = min(26, length / 2)
            let tip = CGPoint(x: end.x - ux * inset, y: end.y - uy * inset)
            let size: CGFloat = touchesLifted ? 9 : 7
            var head = Path()
            head.move(to: tip)
            head.addLine(to: CGPoint(x: tip.x - ux * size - uy * size * 0.55,
                                     y: tip.y - uy * size + ux * size * 0.55))
            head.addLine(to: CGPoint(x: tip.x - ux * size + uy * size * 0.55,
                                     y: tip.y - uy * size - ux * size * 0.55))
            head.closeSubpath()
            context.fill(head, with: .color(color))
        }
    }

    private func binding(for entry: ReferenceEntry) -> Binding<CGPoint> {
        Binding(
            get: { positions[entry.id] ?? CGPoint(x: Self.margin, y: Self.top) },
            set: { positions[entry.id] = $0 })
    }

    /// The seeded plane, overlaid with every card the reader has moved.
    private func load() {
        let seeded = seeds()
        var next = seeded.positions
        if let stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [Double]] {
            for (id, pair) in stored where pair.count == 2 && next[id] != nil {
                next[id] = CGPoint(x: pair[0], y: pair[1])
            }
        }
        positions = next
        yearCaptions = seeded.captions
    }

    private func save() {
        var stored: [String: [Double]] = [:]
        for (id, point) in positions {
            stored[id] = [Double(point.x), Double(point.y)]
        }
        UserDefaults.standard.set(stored, forKey: storeKey)
    }

    /// Years run left to right across the plane; works of nearby years
    /// share a column, stacked; works without a date stand in a last
    /// column of their own.
    private func seeds() -> (positions: [String: CGPoint], captions: [(label: String, x: CGFloat)]) {
        let dated = entries.filter { $0.year != nil }
            .sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
        let undated = entries.filter { $0.year == nil }
        let years = dated.compactMap(\.year)
        let first = years.min() ?? 0, last = years.max() ?? 0
        let span = CGFloat(max(last - first, 1))
        let usable = Self.baseSize.width - 2 * Self.margin - Self.columnWidth
        let columnCount = max(Int(usable / Self.columnWidth), 1)

        var positions: [String: CGPoint] = [:]
        var stacks: [Int: Int] = [:]
        var columnYears: [Int: (low: Int, high: Int)] = [:]
        for entry in dated {
            let year = entry.year ?? first
            let column = min(Int(CGFloat(year - first) / span * CGFloat(columnCount - 1)),
                             columnCount - 1)
            let row = stacks[column, default: 0]
            stacks[column] = row + 1
            positions[entry.id] = CGPoint(
                x: Self.margin + CGFloat(column) * Self.columnWidth,
                y: Self.top + CGFloat(row) * Self.rowHeight)
            let held = columnYears[column] ?? (year, year)
            columnYears[column] = (min(held.low, year), max(held.high, year))
        }
        let lastColumn = (stacks.keys.max() ?? -1) + 1
        for (row, entry) in undated.enumerated() {
            positions[entry.id] = CGPoint(
                x: Self.margin + CGFloat(lastColumn) * Self.columnWidth + 40,
                y: Self.top + CGFloat(row) * Self.rowHeight)
        }
        var captions = columnYears.sorted { $0.key < $1.key }.map { column, range in
            (label: range.low == range.high ? "\(range.low)" : "\(range.low)–\(range.high)",
             x: Self.margin + CGFloat(column) * Self.columnWidth)
        }
        if !undated.isEmpty {
            captions.append((label: "No Date",
                             x: Self.margin + CGFloat(lastColumn) * Self.columnWidth + 40))
        }
        return (positions, captions)
    }
}

/// One keyword under an entry: a pill for the trust keywords, plain text
/// for the rest — shared by the list and (through MapCardMark) the map.
struct ReferenceMarkView: View {
    let mark: MapCardMark
    var size: CGFloat = 11

    var body: some View {
        let color = ProceedingsMapNode.color(for: mark.tone)
        if mark.pill {
            Text(mark.text)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, size * 0.6)
                .padding(.vertical, size * 0.12)
                .background(Capsule().fill(color.opacity(0.12)))
                .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.8))
                .help(mark.detail)
        } else {
            Text(mark.text)
                .font(.system(size: size, weight: mark.tone == .positive ? .semibold : .regular))
                .foregroundStyle(color)
                .help(mark.detail)
        }
    }
}
