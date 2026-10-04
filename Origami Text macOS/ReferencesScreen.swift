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
        // "map" stays the Time Map's stored name, so a kept choice holds.
        case asCited, title, author, date, map, concept
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: "Title"
            case .author: "Author"
            case .date: "Date"
            case .asCited: "As Cited"
            case .map: "Time Map"
            case .concept: "Concept Map"
            }
        }
    }

    // As Cited is where References opens; a new key, so an older kept
    // choice does not hide the new default.
    @AppStorage("referencesListing2") private var listingRaw = Listing.asCited.rawValue

    /// The Time Map's up-and-down order within each year — its View menu.
    enum TimeOrder: String, CaseIterable, Identifiable {
        case arranged, title, author, mostCited, citedHere, citedInPaper, venue, trust
        var id: String { rawValue }
        var label: String {
            switch self {
            case .arranged: "As Arranged"
            case .title: "Title"
            case .author: "First Author"
            case .mostCited: "Most Cited"
            case .citedHere: "Cited by These References"
            case .citedInPaper: "Cited Most in This Paper"
            case .venue: "Venue"
            case .trust: "Trust (warnings first)"
            }
        }
    }

    @AppStorage("referencesTimeMapOrder") private var timeOrderRaw = TimeOrder.arranged.rawValue

    /// The Concept Map's views — the ways bibliometrics lays out a set of
    /// works (VOSviewer, CiteSpace, Connected Papers), from what this
    /// paper and its references already hold.
    enum ConceptView: String, CaseIterable, Identifiable {
        case arranged, network, sharedReferences, citedTogether, section, author, venue, core
        var id: String { rawValue }
        var label: String {
            switch self {
            case .arranged: "As Arranged"
            case .network: "Citation Network"
            case .sharedReferences: "Shared References"
            case .citedTogether: "Cited Together"
            case .section: "By Section"
            case .author: "By Author"
            case .venue: "By Venue"
            case .core: "Core & Periphery"
            }
        }
        var help: String {
            switch self {
            case .arranged: "Where you have put them"
            case .network: "Works that cite each other drawn together"
            case .sharedReferences: "Works that cite the same earlier works drawn together — bibliographic coupling"
            case .citedTogether: "Works this paper cites in the same paragraph drawn together — how the author grouped them"
            case .section: "Gathered under the section of this paper that first cites them"
            case .author: "Gathered under the authors who recur in the list"
            case .venue: "Gathered by journal or conference"
            case .core: "The most connected works at the centre, the rest in rings outward"
            }
        }
    }

    @AppStorage("referencesConceptView") private var conceptViewRaw = ConceptView.arranged.rawValue
    private var conceptView: ConceptView { ConceptView(rawValue: conceptViewRaw) ?? .arranged }

    /// This paper's own facts for the Concept Map, read once per book:
    /// the section that first cites each work, and how often two works
    /// share a paragraph.
    @State private var firstSection: [String: String] = [:]
    /// As Cited: the paper's headings, each followed by the works its
    /// section cites in the order it first cites them — the Outline's
    /// Citations fold, as a page.
    @State private var asCitedOutline: [AsCitedItem] = []

    enum AsCitedItem: Hashable {
        case heading(text: String, level: Int, id: String)
        /// `occurrence` of `total`: the same work under several sections
        /// is numbered in reading order.
        case work(entryID: String, sectionID: String, occurrence: Int, total: Int)
    }
    @State private var togetherCounts: [ReferencesMapView.Pair: Int] = [:]
    private var timeOrder: TimeOrder { TimeOrder(rawValue: timeOrderRaw) ?? .arranged }
    // The reading's theme, as Scroll wears it — edited colours apply live.
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(ThemeColorOverrides.tickKey) private var themeEditTick = 0
    @Environment(\.colorScheme) private var colorScheme

    private var readerTheme: ReaderTheme {
        _ = themeEditTick
        return ReaderTheme(rawValue: themeRaw) ?? .highContrast
    }

    private var themeBackground: Color {
        readerTheme.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor)
    }

    /// Whether the page reads light-on-dark — from the theme's own
    /// background, since a dark theme can stand in the light scheme.
    private var isDarkPage: Bool {
        guard let color = NSColor(themeBackground).usingColorSpace(.sRGB) else {
            return colorScheme == .dark
        }
        let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance < 0.5
    }
    private var listing: Listing { Listing(rawValue: listingRaw) ?? .asCited }

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
            } else if listing == .map || listing == .concept {
                ReferencesMapView(
                    entries: entries,
                    links: links,
                    byTime: listing == .map,
                    lineColor: isDarkPage ? .white : .black,
                    layoutKey: book.id,
                    stamp: statusStamp,
                    marks: { mapMarks(for: $0) },
                    abstractFor: { abstract(forID: $0) },
                    open: { cardKey = CardKey(key: $0.id) },
                    menu: { AnyView(entryMenu($0)) },
                    ordering: listing == .map ? timeOrdering : nil,
                    conceptLayout: listing == .concept ? conceptLayout : .arranged,
                    arranged: {
                        if listing == .map { timeOrderRaw = TimeOrder.arranged.rawValue }
                        else { conceptViewRaw = ConceptView.arranged.rawValue }
                    })
                    // Each map, and each order or view, its own plane:
                    // positions load afresh.
                    .id(listingRaw + "|" + (listing == .map ? timeOrderRaw : conceptViewRaw))
            } else if listing == .asCited {
                asCitedList
            } else {
                list
            }
        }
        // The same theme as Scroll: its background, its ink.
        .foregroundStyle(readerTheme.textColor(for: colorScheme) ?? Color.primary)
        .background(themeBackground)
        .sheet(item: $cardKey) { card in
            if let doc {
                // A cited work that is also one of these references wears
                // an arrow in the card's "Cites" list: click, its card.
                CitationCardSheet(
                    doc: doc, key: card.key,
                    marks: entries.first { $0.id == card.key }.map(allMarks(for:)) ?? [],
                    markWorkKeys: entries.first { $0.id == card.key }.map(workKeys(for:)),
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
            if let found {
                asCitedOutline = Self.asCited(in: found, entries: entries)
                let structure = Self.citationStructure(in: found)
                firstSection = structure.sections
                togetherCounts = structure.together
            }
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
                if listing == .concept {
                    Menu {
                        Picker("Arrange By", selection: $conceptViewRaw) {
                            ForEach(ConceptView.allCases) { view in
                                Text(view.label).tag(view.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text("View")
                    }
                    .fixedSize()
                    .help(conceptView.help)
                }
                if listing == .map {
                    // How each year's column is ordered, top to bottom.
                    Menu {
                        Picker("Order Each Year By", selection: $timeOrderRaw) {
                            ForEach(TimeOrder.allCases) { order in
                                Text(order.label).tag(order.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text("View")
                    }
                    .fixedSize()
                    .help("Order each year's works top to bottom — by title, author, how often cited, and more")
                }
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
        } else if listing == .map || listing == .concept {
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
        case .title, .map, .concept, .asCited:
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
                                .background(themeBackground)
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

    /// The As Cited page: headings in the heading face, stepped in by
    /// level, each section's works under it as the list shows them.
    private var asCitedList: some View {
        let _ = statusStamp
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Each work's sections in reading order, by heading text — the
        // pop-up over its 1st, 2nd… names them.
        var headings: [String: String] = ["uncited": "Not Cited in the Text"]
        var sectionsOf: [String: [String]] = [:]
        for item in asCitedOutline {
            switch item {
            case .heading(let text, _, let id): headings[id] = text
            case .work(let id, let section, _, _):
                sectionsOf[id, default: []].append(headings[section] ?? "Before the First Heading")
            }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(asCitedOutline, id: \.self) { item in
                    switch item {
                    case .heading(let text, let level, _):
                        Text(text)
                            .font(AppFonts.heading(level <= 1 ? 19 : level == 2 ? 16 : 14,
                                                   weight: .semibold))
                            .padding(.top, level <= 1 ? 22 : 14)
                            .padding(.bottom, 4)
                            .padding(.leading, CGFloat(max(level - 1, 0)) * 16)
                    case .work(let id, _, let occurrence, let total):
                        if let entry = byID[id] {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                // Cited in more than one section: which
                                // time this is, in bold.
                                OccurrenceLabel(
                                    label: total > 1 ? Self.ordinal(occurrence) : "",
                                    occurrence: occurrence,
                                    sections: sectionsOf[id] ?? [])
                                    .frame(width: 34, alignment: .trailing)
                                row(entry)
                            }
                            Divider().opacity(0.5)
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

    /// Every heading with the works its section cites — first mention
    /// first, each once per section, as the Citations fold lists them;
    /// works the text never cites gather at the end.
    private static func asCited(in doc: LiquidDoc, entries: [ReferenceEntry]) -> [AsCitedItem] {
        guard let regex = try? NSRegularExpression(pattern: #"\[cite:([^\]]+)\]"#)
        else { return [] }
        let known = Set(entries.map(\.id))
        var items: [AsCitedItem] = []
        var cited = Set<String>()
        var sectionID = "start"
        var seenInSection = Set<String>()
        for paragraph in doc.body ?? [] {
            if let level = paragraph.heading {
                items.append(.heading(text: paragraph.text, level: level, id: paragraph.id))
                sectionID = paragraph.id
                seenInSection = []
                continue
            }
            guard paragraph.text.contains("[cite:") else { continue }
            let text = paragraph.text as NSString
            for match in regex.matches(in: paragraph.text,
                                       range: NSRange(location: 0, length: text.length)) {
                for raw in text.substring(with: match.range(at: 1)).split(separator: ",") {
                    let key = raw.trimmingCharacters(in: .whitespaces)
                    guard known.contains(key), seenInSection.insert(key).inserted else { continue }
                    items.append(.work(entryID: key, sectionID: sectionID, occurrence: 0, total: 0))
                    cited.insert(key)
                }
            }
        }
        // Headings that cite nothing stay: the outline is the paper's.
        let uncited = entries.filter { !cited.contains($0.id) }
        if !uncited.isEmpty {
            items.append(.heading(text: "Not Cited in the Text", level: 1, id: "uncited"))
            for entry in uncited {
                items.append(.work(entryID: entry.id, sectionID: "uncited", occurrence: 0, total: 0))
            }
        }
        // Number each work's appearances in reading order.
        var totals: [String: Int] = [:]
        for item in items {
            if case .work(let id, _, _, _) = item { totals[id, default: 0] += 1 }
        }
        var seen: [String: Int] = [:]
        return items.map { item in
            guard case .work(let id, let section, _, _) = item else { return item }
            seen[id, default: 0] += 1
            return .work(entryID: id, sectionID: section,
                         occurrence: seen[id] ?? 1, total: totals[id] ?? 1)
        }
    }

    static func ordinal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func row(_ entry: ReferenceEntry) -> some View {
        Button {
            cardKey = CardKey(key: entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                // Sorted by author, the names read black and the title
                // steps back to grey — the same fonts either way.
                let byAuthor = listing == .author
                // By author the sizes trade places too: the names read
                // large, the title at the byline's size, each in its own
                // face.
                Text(entry.title)
                    .font(AppFonts.body(byAuthor ? Self.calloutSize : 16))
                    .foregroundStyle(byAuthor ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                let byline = byline(for: entry)
                if !byline.isEmpty {
                    bylineText(for: entry, byAuthor: byAuthor)
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
            return Text(byline(for: entry)).font(.callout).foregroundStyle(.secondary)
        }
        let rest = [entry.year.map(String.init) ?? "", entry.venue]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let names = Text(entry.authors).font(.system(size: 14)).foregroundStyle(.primary)
        return rest.isEmpty ? names
            : names + Text(" · " + rest).font(.callout).foregroundStyle(.secondary)
    }

    /// The callout style's size on this Mac — the byline's size.
    private static var calloutSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .callout).pointSize
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

    /// The marks shown under an entry: all of them, less any the reader
    /// removed from its card.
    private func marks(for entry: ReferenceEntry) -> [ReferenceStatus.Mark] {
        ReferenceStatus.visible(allMarks(for: entry), for: workKeys(for: entry))
    }

    private func resolvedDOI(for entry: ReferenceEntry) -> String? {
        entry.doi ?? foundDOIs[entry.id]
            ?? ReferenceStatus.cleanDOI(CitationGraph.cached(forKey: entry.graphKey)?.doi)
    }

    private func workKeys(for entry: ReferenceEntry) -> [String] {
        ReferenceStatus.workKeys(doi: resolvedDOI(for: entry), title: entry.title)
    }

    /// Every mark the sources give the entry, removals or not — the card
    /// needs them to offer Restore.
    private func allMarks(for entry: ReferenceEntry) -> [ReferenceStatus.Mark] {
        let doi = resolvedDOI(for: entry)
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

    /// The Time Map's order within a year: true when the first work
    /// should stand above the second. Nil keeps the reader's arrangement.
    private var timeOrdering: ((ReferenceEntry, ReferenceEntry) -> Bool)? {
        func cited(_ entry: ReferenceEntry) -> Int {
            ReferenceStatus.cachedLive(doi: resolvedDOI(for: entry))?.citedBy ?? 0
        }
        func gravity(_ entry: ReferenceEntry) -> Int {
            let marks = marks(for: entry)
            if marks.contains(where: { $0.tone == .alarm }) { return 0 }
            if marks.contains(where: { $0.tone == .caution }) { return 1 }
            if marks.contains(where: { $0.pill }) { return 2 }
            return 3
        }
        func byTitle(_ a: ReferenceEntry, _ b: ReferenceEntry) -> Bool {
            a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        switch timeOrder {
        case .arranged: return nil
        case .title: return byTitle
        case .author:
            return { ($0.familyKey, $0.title) < ($1.familyKey, $1.title) }
        case .mostCited:
            return { let a = cited($0), b = cited($1); return a != b ? a > b : byTitle($0, $1) }
        case .citedHere:
            return {
                let a = neighbourCounts[$0.id] ?? 0, b = neighbourCounts[$1.id] ?? 0
                return a != b ? a > b : byTitle($0, $1)
            }
        case .citedInPaper:
            return {
                let a = textCounts[$0.id] ?? 0, b = textCounts[$1.id] ?? 0
                return a != b ? a > b : byTitle($0, $1)
            }
        case .venue:
            return {
                let a = $0.venue.isEmpty ? "\u{10FFFF}" : $0.venue
                let b = $1.venue.isEmpty ? "\u{10FFFF}" : $1.venue
                return a != b ? a.localizedStandardCompare(b) == .orderedAscending : byTitle($0, $1)
            }
        case .trust:
            return { let a = gravity($0), b = gravity($1); return a != b ? a < b : byTitle($0, $1) }
        }
    }

    // MARK: The Concept Map's views

    /// What the chosen view asks of the plane.
    private var conceptLayout: ReferencesMapView.ConceptLayout {
        switch conceptView {
        case .arranged:
            return .arranged
        case .network:
            return .force(links.map { .init(from: $0.from, to: $0.to, weight: 1) })
        case .sharedReferences:
            return .force(sharedReferenceEdges())
        case .citedTogether:
            return .force(togetherCounts.map {
                .init(from: $0.key.a, to: $0.key.b, weight: CGFloat($0.value))
            })
        case .section:
            return .groups(entries.reduce(into: [:]) { groups, entry in
                groups[entry.id] = firstSection[entry.id] ?? "Not Cited in the Text"
            })
        case .author:
            return .groups(authorGroups())
        case .venue:
            return .groups(venueGroups())
        case .core:
            var degree: [String: Double] = [:]
            for link in links {
                degree[link.from, default: 0] += 1
                degree[link.to, default: 0] += 1
            }
            return .radial(degree)
        }
    }

    /// Bibliographic coupling: two works joined as strongly as their
    /// reference lists overlap (Jaccard), from the shelf's copy or the
    /// citation graph — DOIs where known, folded titles otherwise.
    private func sharedReferenceEdges() -> [ReferencesMapView.WeightedLink] {
        var sets: [(id: String, refs: Set<String>)] = []
        for entry in entries {
            let cited: [CitationGraph.CitedRef]
            var dois: [String] = []
            if let own = libraryReferences(for: entry) {
                cited = own
            } else if let graph = CitationGraph.cached(forKey: entry.graphKey), graph.found {
                cited = graph.references
                dois = graph.citedDOIs ?? []
            } else {
                continue
            }
            var refs = Set(dois)
            for reference in cited {
                if let doi = ReferenceStatus.cleanDOI(reference.doi) {
                    refs.insert(doi)
                } else {
                    let title = ReferenceStatus.normalizedTitle(reference.title)
                    if title.count >= 12 { refs.insert("t:" + title) }
                }
            }
            if !refs.isEmpty { sets.append((entry.id, refs)) }
        }
        var edges: [ReferencesMapView.WeightedLink] = []
        for (i, a) in sets.enumerated() {
            for b in sets[(i + 1)...] {
                let shared = a.refs.intersection(b.refs).count
                guard shared >= 2 else { continue }
                let jaccard = CGFloat(shared) / CGFloat(a.refs.union(b.refs).count)
                edges.append(.init(from: a.id, to: b.id, weight: 1 + jaccard * 8))
            }
        }
        return edges
    }

    /// Each work under the author it shares with most of the list; works
    /// whose authors appear once gather as "Single Appearances".
    private func authorGroups() -> [String: String] {
        func names(_ entry: ReferenceEntry) -> [String] {
            entry.authors.components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "others" }
        }
        var counts: [String: Int] = [:]
        for entry in entries { for name in Set(names(entry)) { counts[name, default: 0] += 1 } }
        return entries.reduce(into: [:]) { groups, entry in
            let best = names(entry).filter { (counts[$0] ?? 0) >= 2 }
                .max { (counts[$0] ?? 0, $1) < (counts[$1] ?? 0, $0) }
            groups[entry.id] = best ?? (names(entry).isEmpty ? "No Author" : "Single Appearances")
        }
    }

    /// Each work under its venue; venues that appear once gather together.
    private func venueGroups() -> [String: String] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.venue.isEmpty { counts[entry.venue, default: 0] += 1 }
        return entries.reduce(into: [:]) { groups, entry in
            if entry.venue.isEmpty { groups[entry.id] = "No Venue" }
            else if (counts[entry.venue] ?? 0) >= 2 { groups[entry.id] = entry.venue }
            else { groups[entry.id] = "Other Venues" }
        }
    }

    /// The paper's own structure: the heading over each work's first
    /// citation, and how many paragraphs cite each pair of works together.
    private static func citationStructure(in doc: LiquidDoc)
        -> (sections: [String: String], together: [ReferencesMapView.Pair: Int]) {
        guard let regex = try? NSRegularExpression(pattern: #"\[cite:([^\]]+)\]"#)
        else { return ([:], [:]) }
        var sections: [String: String] = [:]
        var together: [ReferencesMapView.Pair: Int] = [:]
        var heading = "Before the First Heading"
        for paragraph in doc.body ?? [] {
            if let level = paragraph.heading, level <= 2 {
                // Printed numbers off: "2.1 Related Work" reads "Related Work".
                heading = paragraph.text
                    .replacingOccurrences(of: #"^[\d.]+\s+"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            guard paragraph.text.contains("[cite:") else { continue }
            let text = paragraph.text as NSString
            var keys: [String] = []
            for match in regex.matches(in: paragraph.text,
                                       range: NSRange(location: 0, length: text.length)) {
                for key in text.substring(with: match.range(at: 1)).split(separator: ",") {
                    keys.append(key.trimmingCharacters(in: .whitespaces))
                }
            }
            for key in keys where sections[key] == nil { sections[key] = heading }
            let distinct = Array(Set(keys)).sorted()
            for (i, a) in distinct.enumerated() {
                for b in distinct[(i + 1)...] {
                    together[ReferencesMapView.Pair(a: a, b: b), default: 0] += 1
                }
            }
        }
        return (sections, together)
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

    /// Two works, unordered — a pair cited in one paragraph.
    struct Pair: Hashable {
        let a: String
        let b: String
    }

    struct WeightedLink {
        let from: String
        let to: String
        let weight: CGFloat
    }

    /// How the Concept Map lays its cards: where the reader put them, by
    /// forces along weighted ties, in labelled groups, or in rings by score.
    enum ConceptLayout {
        case arranged
        case force([WeightedLink])
        case groups([String: String])
        case radial([String: Double])
    }

    let entries: [ReferenceEntry]
    let links: [Link]
    /// The Time Map: years across, cards move up and down only. Off, the
    /// Concept Map: no years, cards go anywhere the reader puts them.
    var byTime = true
    /// Black on a light page, white on a dark one.
    var lineColor: Color = .primary
    let layoutKey: String
    /// Redraw beat — standings and lines landing.
    let stamp: Int
    let marks: (ReferenceEntry) -> [MapCardMark]
    let abstractFor: (String) -> String
    let open: (ReferenceEntry) -> Void
    let menu: (ReferenceEntry) -> AnyView
    /// The Time Map's order within each year; nil keeps the reader's own
    /// arrangement (and the seeded year-then-title order before it).
    var ordering: ((ReferenceEntry, ReferenceEntry) -> Bool)? = nil
    /// The Concept Map's view; `.arranged` keeps the reader's own places.
    var conceptLayout: ConceptLayout = .arranged

    /// A view the plane computes rather than the reader's arrangement.
    private var isComputed: Bool {
        if byTime { return ordering != nil }
        if case .arranged = conceptLayout { return false }
        return true
    }
    /// The reader moved a card while an order stood: the plane becomes
    /// theirs — the screen switches back to As Arranged.
    var arranged: () -> Void = {}

    @State private var positions: [String: CGPoint] = [:]
    @State private var liftedID: String?
    @State private var liveDrag = MapLiveDrag()
    @State private var yearCaptions: [(label: String, x: CGFloat)] = []
    /// The grouped views' names, standing over their groups.
    @State private var groupCaptions: [(label: String, at: CGPoint)] = []
    /// ⌘A's selection: every card wears the ring, and dragging any one
    /// carries the rest. A click on the empty plane lets go.
    @State private var selectedIDs: Set<String> = []
    @State private var groupDragBase: [String: CGPoint]?
    @State private var selectAllMonitor: Any?

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
    /// The Time Map's year columns: a closed card (159) and a narrow
    /// gutter, so the years stand close.
    private static let yearColumnWidth: CGFloat = 172
    private static let rowHeight: CGFloat = 64
    private static let top: CGFloat = 150

    private var storeKey: String {
        (byTime ? "referencesMap:" : "referencesConceptMap:") + layoutKey
    }

    var body: some View {
        let _ = stamp
        let connected = connectedIDs
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                // The empty plane: a click there sets the lifted card down.
                Color.clear
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        liftedID = nil
                        selectedIDs = []
                    }
                ForEach(groupCaptions.indices, id: \.self) { index in
                    Text(groupCaptions[index].label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: 360, alignment: .leading)
                        .position(groupCaptions[index].at)
                        .allowsHitTesting(false)
                }
                ForEach(yearCaptions.indices, id: \.self) { index in
                    // The theme's heading ink: in Scroll a heading wears the
                    // theme's own text colour, and so does each year here.
                    Text(yearCaptions[index].label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
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
                        isGrouped: selectedIDs.contains(entry.id),
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
                        groupDragged: { translation in
                            groupDragged(entry, translation: translation)
                        },
                        moved: {
                            groupDragBase = nil
                            save()
                            // A hand move ends a sorted view: the sorted
                            // places become the reader's own to change.
                            if isComputed { arranged() }
                        },
                        liveMoved: { point in
                            liveDrag.id = point == nil ? nil : entry.id
                            if let point { liveDrag.point = point }
                        },
                        marks: marks(entry),
                        menu: { menu(entry) },
                        standingTitleLines: 2,
                        roomyWhenLifted: true,
                        verticalOnly: byTime)
                    .zIndex(liftedID == entry.id ? 1 : 0)
                }
            }
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color.secondary.opacity(0.06))
        .onAppear(perform: load)
        // ⌘A takes the whole plane — unless a text field is writing.
        .onAppear {
            guard selectAllMonitor == nil else { return }
            selectAllMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "a",
                      !(NSApp.keyWindow?.firstResponder is NSTextView)
                else { return event }
                selectedIDs = Set(entries.map(\.id))
                return nil
            }
        }
        .onDisappear {
            if let selectAllMonitor { NSEvent.removeMonitor(selectAllMonitor) }
            selectAllMonitor = nil
        }
        .onChange(of: entries.map(\.id)) { load() }
        // A sorted Time Map re-sorts as counts and lines land.
        .onChange(of: stamp) {
            if isComputed { load() }
        }
        // The Concept Map gathers by its lines, which land while the
        // works' reference lists are read: until the reader has moved a
        // card, it re-gathers as they come.
        .onChange(of: links) {
            guard !byTime, UserDefaults.standard.dictionary(forKey: storeKey) == nil else { return }
            load()
        }
    }

    /// A member of the ⌘A selection in hand: the others follow it — on the
    /// Time Map up and down only, as each card moves alone.
    private func groupDragged(_ entry: ReferenceEntry, translation: CGSize) {
        guard selectedIDs.contains(entry.id), selectedIDs.count > 1 else { return }
        let base = groupDragBase ?? {
            let snapshot = positions.filter { selectedIDs.contains($0.key) }
            groupDragBase = snapshot
            return snapshot
        }()
        for (id, start) in base where id != entry.id {
            positions[id] = CGPoint(
                x: byTime ? start.x : max(start.x + translation.width, 90),
                y: max(start.y + translation.height, 40))
        }
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
            // No arrowheads: the newer work cites the older, always — the
            // years left to right already say which way a line runs.
            let color = lineColor.opacity(quiet ? 0.08 : touchesLifted ? 0.85 : 0.35)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), lineWidth: touchesLifted ? 2 : 1.2)
        }
    }

    private func binding(for entry: ReferenceEntry) -> Binding<CGPoint> {
        Binding(
            get: { positions[entry.id] ?? CGPoint(x: Self.margin, y: Self.top) },
            set: { positions[entry.id] = $0 })
    }

    /// The seeded plane, overlaid with every card the reader has moved.
    private func load() {
        let seededPositions: [String: CGPoint]
        let seededCaptions: [(label: String, x: CGFloat)]
        if byTime {
            let seeded = seeds()
            seededPositions = seeded.positions
            seededCaptions = seeded.captions
        } else {
            switch conceptLayout {
            case .arranged:
                seededPositions = conceptSeeds()
            case .force(let edges):
                seededPositions = forceLayout(edges.map { ($0.from, $0.to, $0.weight) })
            case .groups(let labels):
                let laid = groupLayout(labels)
                seededPositions = laid.positions
                groupCaptions = laid.captions
            case .radial(let scores):
                seededPositions = radialLayout(scores)
            }
            seededCaptions = []
        }
        if case .groups = conceptLayout, !byTime {} else { groupCaptions = [] }
        var next = seededPositions
        // A computed concept view may reach past the plane's top or left
        // (wide rings): it is moved in whole, since the plane scrolls
        // only right and down.
        if !byTime, isComputed {
            let minX = next.values.map(\.x).min() ?? Self.margin
            let minY = next.values.map(\.y).min() ?? Self.top
            let dx = max(Self.margin - minX, 0), dy = max(Self.top - minY, 0)
            if dx > 0 || dy > 0 {
                next = next.mapValues { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                groupCaptions = groupCaptions.map { ($0.label, CGPoint(x: $0.at.x + dx, y: $0.at.y + dy)) }
            }
        }
        // A computed view stands as computed; the reader's own places wait.
        if !isComputed,
           let stored = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: [Double]] {
            for (id, pair) in stored where pair.count == 2 {
                guard let seat = next[id] else { continue }
                // On the Time Map only the height is the reader's: across,
                // a card always stands at its year. The Concept Map keeps
                // wherever it was put.
                next[id] = byTime ? CGPoint(x: seat.x, y: pair[1])
                                  : CGPoint(x: pair[0], y: pair[1])
            }
        }
        positions = next
        yearCaptions = seededCaptions
    }

    /// The Concept Map's first arrangement: works that cite each other
    /// drawn together, the rest kept apart — a few hundred rounds of
    /// springs along the lines and push between every pair, from a
    /// deterministic ring, so the same list always opens the same way.
    private func conceptSeeds() -> [String: CGPoint] {
        forceLayout(links.map { ($0.from, $0.to, 1) })
    }

    /// Springs along weighted ties, push between every pair: stronger ties
    /// pull harder and sit closer.
    private func forceLayout(_ edges: [(String, String, CGFloat)]) -> [String: CGPoint] {
        let ids = entries.map(\.id)
        guard !ids.isEmpty else { return [:] }
        let centre = CGPoint(x: Self.baseSize.width / 2, y: Self.baseSize.height / 2)
        var points: [String: CGPoint] = [:]
        let radius = min(Self.baseSize.width, Self.baseSize.height) * 0.38
        for (index, id) in ids.enumerated() {
            let angle = Double(index) / Double(ids.count) * 2 * .pi
            points[id] = CGPoint(x: centre.x + radius * cos(angle),
                                 y: centre.y + radius * sin(angle))
        }
        let joined = edges.filter { points[$0.0] != nil && points[$0.1] != nil }
        let spring: CGFloat = 230, push: CGFloat = 60_000
        for round in 0..<300 {
            let step = 0.9 * (1 - CGFloat(round) / 300) + 0.05
            var move: [String: CGVector] = [:]
            for (i, a) in ids.enumerated() {
                for b in ids[(i + 1)...] {
                    guard let pa = points[a], let pb = points[b] else { continue }
                    let dx = pa.x - pb.x, dy = pa.y - pb.y
                    let d2 = max(dx * dx + dy * dy, 100)
                    let force = push / d2
                    let d = sqrt(d2)
                    move[a, default: .zero].dx += dx / d * force
                    move[a, default: .zero].dy += dy / d * force
                    move[b, default: .zero].dx -= dx / d * force
                    move[b, default: .zero].dy -= dy / d * force
                }
            }
            for (from, to, weight) in joined {
                guard let pa = points[from], let pb = points[to] else { continue }
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                let d = max(sqrt(dx * dx + dy * dy), 1)
                let rest = spring / sqrt(max(weight, 1))
                let pull = (d - rest) * 0.05 * min(weight, 4)
                move[from, default: .zero].dx += dx / d * pull
                move[from, default: .zero].dy += dy / d * pull
                move[to, default: .zero].dx -= dx / d * pull
                move[to, default: .zero].dy -= dy / d * pull
            }
            for id in ids {
                guard var p = points[id], let m = move[id] else { continue }
                // A gentle pull to the middle keeps loners on the plane.
                p.x += (m.dx + (centre.x - p.x) * 0.01) * step
                p.y += (m.dy + (centre.y - p.y) * 0.01) * step
                p.x = min(max(p.x, Self.margin), Self.baseSize.width - Self.margin)
                p.y = min(max(p.y, Self.top - 40), Self.baseSize.height - 80)
                points[id] = p
            }
        }
        return points
    }

    private func save() {
        var stored: [String: [Double]] = [:]
        for (id, point) in positions {
            stored[id] = [Double(point.x), Double(point.y)]
        }
        UserDefaults.standard.set(stored, forKey: storeKey)
    }

    /// Labelled groups, largest first, each a block of columns eight
    /// cards deep under its name, the blocks wrapping across the plane.
    private func groupLayout(_ labels: [String: String])
        -> (positions: [String: CGPoint], captions: [(label: String, at: CGPoint)]) {
        var members: [String: [ReferenceEntry]] = [:]
        for entry in entries { members[labels[entry.id] ?? "Other", default: []].append(entry) }
        // Largest first; the catch-all groups last.
        let catchAll: Set<String> = ["Single Appearances", "Other Venues", "No Venue",
                                     "No Author", "Not Cited in the Text", "Other"]
        let order = members.keys.sorted {
            let a = catchAll.contains($0), b = catchAll.contains($1)
            if a != b { return !a }
            let ca = members[$0]?.count ?? 0, cb = members[$1]?.count ?? 0
            return ca != cb ? ca > cb : $0 < $1
        }
        let depth = 8
        var positions: [String: CGPoint] = [:]
        var captions: [(label: String, at: CGPoint)] = []
        var x = Self.margin, y = Self.top
        var rowHeight: CGFloat = 0
        for label in order {
            let group = (members[label] ?? []).sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let columns = Int(ceil(Double(group.count) / Double(depth)))
            let width = CGFloat(columns) * Self.columnWidth
            let height = CGFloat(min(group.count, depth)) * Self.rowHeight + 70
            if x + width > Self.baseSize.width - Self.margin / 2, x > Self.margin {
                x = Self.margin
                y += rowHeight + 30
                rowHeight = 0
            }
            captions.append((label, CGPoint(x: x + 100, y: y - 44)))
            for (index, entry) in group.enumerated() {
                positions[entry.id] = CGPoint(x: x + CGFloat(index / depth) * Self.columnWidth,
                                              y: y + CGFloat(index % depth) * Self.rowHeight)
            }
            x += width + 70
            rowHeight = max(rowHeight, height)
        }
        return (positions, captions)
    }

    /// Rings by score: the highest at the centre, each ring outward
    /// holding more, the unconnected on the outermost.
    private func radialLayout(_ scores: [String: Double]) -> [String: CGPoint] {
        let centre = CGPoint(x: Self.baseSize.width / 2, y: Self.baseSize.height / 2 + 60)
        let ranked = entries.sorted {
            let a = scores[$0.id] ?? 0, b = scores[$1.id] ?? 0
            return a != b ? a > b : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        var positions: [String: CGPoint] = [:]
        var index = 0
        var ring = 0
        while index < ranked.count {
            let capacity = ring == 0 ? 1 : 7 * ring
            let radius = CGFloat(ring) * 210
            let members = ranked[index..<min(index + capacity, ranked.count)]
            for (slot, entry) in members.enumerated() {
                // Each ring turned a little, so its cards fall between the
                // inner ring's.
                let angle = (Double(slot) / Double(max(members.count, 1)) + Double(ring) * 0.13) * 2 * .pi
                positions[entry.id] = CGPoint(x: centre.x + radius * cos(angle) * 1.25,
                                              y: centre.y + radius * sin(angle))
            }
            index += capacity
            ring += 1
        }
        return positions
    }

    /// Years run left to right across the plane; works of nearby years
    /// share a column, stacked; works without a date stand in a last
    /// column of their own.
    private func seeds() -> (positions: [String: CGPoint], captions: [(label: String, x: CGFloat)]) {
        let dated = entries.filter { $0.year != nil }
            .sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
        let undated = entries.filter { $0.year == nil }

        // One column per year that has works — never a span of years under
        // one heading. Years with nothing between them sit a column apart;
        // a gap in time adds a little air (capped, so a quiet decade does
        // not push the plane wide). A column is wider than a closed card,
        // so neighbours never overlap.
        let years = Array(Set(dated.compactMap(\.year))).sorted()
        var columnX: [Int: CGFloat] = [:]
        var x = Self.margin
        for (index, year) in years.enumerated() {
            if index > 0 {
                let skipped = year - years[index - 1] - 1
                x += Self.yearColumnWidth + CGFloat(min(skipped, 4)) * 12
            }
            columnX[year] = x
        }

        var positions: [String: CGPoint] = [:]
        // Each work to its year's column; each column stacked in the chosen
        // order (year, then title, when none is chosen).
        var columns: [Int: [ReferenceEntry]] = [:]
        for entry in dated {
            if let year = entry.year { columns[year, default: []].append(entry) }
        }
        for (year, members) in columns {
            let stacked = ordering.map { members.sorted(by: $0) } ?? members
            for (row, entry) in stacked.enumerated() {
                positions[entry.id] = CGPoint(x: columnX[year] ?? Self.margin,
                                              y: Self.top + CGFloat(row) * Self.rowHeight)
            }
        }
        let undatedX = (years.last.flatMap { columnX[$0] }.map { $0 + Self.yearColumnWidth + 30 })
            ?? Self.margin
        let undatedStacked = ordering.map { undated.sorted(by: $0) } ?? undated
        for (row, entry) in undatedStacked.enumerated() {
            positions[entry.id] = CGPoint(x: undatedX,
                                          y: Self.top + CGFloat(row) * Self.rowHeight)
        }
        var captions = years.map { (label: "\($0)", x: columnX[$0] ?? Self.margin) }
        if !undated.isEmpty {
            captions.append((label: "No Date", x: undatedX))
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

/// As Cited's "2nd" beside a work cited in several sections: hovered, a
/// pop-up names every section that cites it, this one in bold.
struct OccurrenceLabel: View {
    let label: String
    let occurrence: Int
    let sections: [String]
    @State private var showing = false

    var body: some View {
        Text(label)
            .font(AppFonts.body(16, weight: .bold))
            .onHover { inside in
                guard !label.isEmpty else { return }
                showing = inside
            }
            .popover(isPresented: $showing, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cited in \(sections.count) sections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ReferencesScreen.ordinal(index + 1))
                                .font(.callout.weight(.semibold))
                                .frame(width: 34, alignment: .trailing)
                            Text(section)
                                .font(.callout.weight(index + 1 == occurrence ? .bold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(width: 320, alignment: .leading)
            }
    }
}
