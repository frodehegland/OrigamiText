import SwiftUI

/// Library ▸ References: the master list — every work the library cites,
/// each once, however many papers cite it and however each wrote it —
/// from the record Check Library Now keeps in the community folder
/// (origami-cited-works.json). Sorted by the Title, Author or Date tab
/// (a second click reverses); each row shows what it is sorted by, with
/// its gravest warning beside.
struct CitedWorksListView: View {
    @Environment(AppModel.self) private var model
    /// Bumped when the record is read again, so the list redraws.
    @State private var readStamp = 0
    /// Title, Author or Date, and which way — a second click on the
    /// chosen tab reverses it, as every list's tabs do.
    @AppStorage("citedWorksSortKey") private var sortKey = "title"
    @AppStorage("citedWorksSortAscending") private var ascending = true

    typealias Entry = (key: String, work: ReferenceStatus.CitedWork)

    /// One work per entry: a work found by its title is kept under both
    /// its title and its DOI, and shows once.
    private var entries: [Entry] {
        _ = readStamp
        let all = ReferenceStatus.shared
        return all.filter { key, work in
            guard key.hasPrefix("title:"), let doi = work.doi else { return true }
            return all[doi] == nil
        }
        .map { ($0.key, $0.value) }
    }

    /// The entry's title, as shown.
    static func title(_ entry: Entry) -> String {
        entry.work.title ?? entry.key.replacingOccurrences(of: "title:", with: "")
    }

    /// The first author's surname, for sorting by author.
    private static func surname(_ entry: Entry) -> String? {
        guard let first = entry.work.authors?.first else { return nil }
        let name = first.contains(",") ? String(first.split(separator: ",")[0]) : first
        return (name.split(separator: " ").last.map(String.init) ?? name)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private var sorted: [Entry] {
        // The foot Find, as every list has it.
        let found = entries.filter { entry in
            model.matchesFind([entry.work.title, entry.work.authors?.joined(separator: " "), entry.work.doi]
                .compactMap { $0 }.joined(separator: " "))
        }
        func byTitle(_ a: Entry, _ b: Entry) -> Bool {
            Self.title(a).localizedCaseInsensitiveCompare(Self.title(b)) == .orderedAscending
        }
        // Works without an author, or without a year, stand last either way.
        switch sortKey {
        case "author":
            return found.sorted { a, b in
                switch (Self.surname(a), Self.surname(b)) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byTitle(a, b)
                }
            }
        case "date":
            return found.sorted { a, b in
                switch (a.work.year, b.work.year) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byTitle(a, b)
                }
            }
        default:
            return found.sorted { ascending ? byTitle($0, $1) : byTitle($1, $0) }
        }
    }

    /// Choosing a work shows its card — closing a paper opened from the
    /// last card, which otherwise keeps the reading pane.
    private var chooseWork: Binding<String?> {
        Binding(
            get: { model.selectedCitedWorkKey },
            set: { key in
                if key != nil { model.openEPUB = nil }
                model.selectedCitedWorkKey = key
            })
    }

    var body: some View {
        let check = CitedWorksCheck.shared
        VStack(spacing: 0) {
            ReferenceSortTabs(key: $sortKey, ascending: $ascending)
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(check.isRunning ? "Gathering the References" : "No Master List Yet",
                          systemImage: "text.quote")
                } description: {
                    Text(check.isRunning
                         ? "Checking \(check.done.formatted()) of \(check.total.formatted()) cited works…"
                         : "Check Library Now looks up every work your library cites — once each, politely — and keeps what it finds in the community folder, for this Mac and your headset.")
                } actions: {
                    if !check.isRunning {
                        Button("Check Library Now") {
                            check.start(docs: model.index.allByID.mapValues(\.doc),
                                        folder: model.index.folderURL)
                        }
                        .disabled(model.index.folderURL == nil)
                    }
                }
            } else {
                List(selection: chooseWork) {
                    Section {
                        ForEach(sorted, id: \.key) { entry in
                            CitedWorkRow(entry: entry, sortKey: sortKey)
                                .tag(entry.key)
                                // A click on the work already chosen is no
                                // change of selection: it still brings its
                                // card back over a paper opened from it.
                                .simultaneousGesture(TapGesture().onEnded {
                                    model.openEPUB = nil
                                })
                        }
                    } header: {
                        Text("\(entries.count.formatted()) works cited")
                    }
                }
                .contentMargins(.top, 0, for: .scrollContent)
            }
        }
        // The record as the folder holds it, read again while a check
        // writes it.
        .task {
            await ReferenceStatus.adoptShared(from: model.index.folderURL)
            readStamp += 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await ReferenceStatus.adoptShared(from: model.index.folderURL)
                readStamp += 1
            }
        }
    }
}

/// Title | Author | Date above the references, in the shelf's own tab
/// look: a click chooses, a second click reverses. Title starts A–Z,
/// Author A–Z by surname, Date newest first.
struct ReferenceSortTabs: View {
    @Binding var key: String
    @Binding var ascending: Bool
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(ThemeColorOverrides.tickKey) private var themeTick = 0
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .highContrast }

    var body: some View {
        HStack(spacing: 2) {
            tab("Title", value: "title", startsAscending: true)
            tab("Author", value: "author", startsAscending: true)
            tab("Date", value: "date", startsAscending: false)
            tab("Map", value: "map", startsAscending: true)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tab(_ title: String, value: String, startsAscending: Bool) -> some View {
        let chosen = key == value
        return Button {
            if chosen { ascending.toggle() } else { key = value; ascending = startsAscending }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                // The Map has no order to reverse.
                if chosen, value != "map" {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .foregroundStyle(theme.textColor(for: colorScheme) ?? Color.primary)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(chosen ? (theme.background(for: colorScheme)
                                ?? Color(nsColor: .controlBackgroundColor)) : .clear)
                .shadow(color: .black.opacity(chosen ? 0.12 : 0), radius: 1, y: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(value == "map" ? "Every paper and the works it cites, on a Map"
              : chosen ? "Click again to reverse" : "Sort by \(title.lowercased())")
    }
}

/// One work, saying what it is sorted by: its title under Title, its
/// authors under Author, both (and the year) under Date — with its
/// gravest warning beside, whichever.
private struct CitedWorkRow: View {
    let entry: CitedWorksListView.Entry
    let sortKey: String

    var body: some View {
        let work = entry.work
        let warning = ReferenceStatus.standingWarning(doi: work.doi, title: work.title ?? "",
                                                      year: work.year)
        let authors = work.authors?.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let warning { MarkPill(mark: warning) }
                switch sortKey {
                case "author":
                    Text(authors ?? "Unknown author")
                        .font(.system(size: 12.5))
                        .foregroundStyle(authors == nil ? .secondary : .primary)
                        .lineLimit(2)
                default:
                    Text(CitedWorksListView.title(entry))
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                }
            }
            if sortKey == "date" {
                let byline = [authors, work.year.map(String.init)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !byline.isEmpty {
                    Text(byline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
    }
}

/// A keyword as a small pill, coloured by what it says.
private struct MarkPill: View {
    let mark: ReferenceStatus.Mark

    var body: some View {
        let color: Color = switch mark.tone {
        case .alarm: .red
        case .caution: .orange
        case .info: .blue
        case .good: .green
        case .positive: .accentColor
        case .quiet: .secondary
        }
        Text(mark.text)
            .font(.system(size: 10, weight: mark.pill ? .semibold : .regular))
            .foregroundStyle(color)
            .padding(.horizontal, mark.pill ? 6 : 0)
            .padding(.vertical, mark.pill ? 1 : 0)
            .overlay {
                if mark.pill { Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1) }
            }
            .help(mark.detail)
    }
}

/// Everything the master list knows of one work: what it is, whether it
/// can be trusted (each keyword with its meaning and evidence), what it
/// says, how it is cited, and which of the shelf's papers cite it — each
/// opening on a click.
struct CitedWorkDetailView: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        if let work = ReferenceStatus.shared[key] {
            ScrollView {
                details(work)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("Not in the Master List", systemImage: "quote.opening")
        }
    }

    /// The first passage of a paper that cites the work: the paper's own
    /// reference that is this work — the same DOI, or the same folded
    /// title — and the first paragraph whose [cite:] names it.
    static func citingParagraph(in record: EPUBRecord, of work: ReferenceStatus.CitedWork,
                                key: String, model: AppModel) -> String? {
        guard let doc = model.index.allByID[record.id]?.doc ?? model.index.byID[record.id]?.doc
        else { return nil }
        let wantedDOI = work.doi
        let wantedTitles = Set([work.title, key.hasPrefix("title:") ? String(key.dropFirst(6)) : nil]
            .compactMap { $0 }.map(ReferenceStatus.normalizedTitle))
        let keys = Set(doc.references.compactMap { reference -> String? in
            let bib = BibTeXRecord.records(in: reference.bibtex).first
            let doi = ReferenceStatus.cleanDOI(bib?.fields["doi"])
            if let wantedDOI, doi == wantedDOI { return reference.id }
            let title = bib?.title.isEmpty == false ? bib!.title : (reference.citedAs ?? "")
            if ReferenceStatus.sharedKey(doi: doi, title: title) == key { return reference.id }
            return wantedTitles.contains(ReferenceStatus.normalizedTitle(title)) ? reference.id : nil
        })
        guard !keys.isEmpty else { return nil }
        return doc.body?.first { paragraph in
            paragraph.text.contains("[cite") && !keys.isDisjoint(with: Transpoint.citationKeys(in: paragraph.text))
        }?.id
    }

    @ViewBuilder private func details(_ work: ReferenceStatus.CitedWork) -> some View {
        let live = work.live
        let marks = ReferenceStatus.marks(for: .init(doi: work.doi, title: work.title ?? "",
                                                     year: work.year))
        VStack(alignment: .leading, spacing: 14) {
            Text(work.title ?? key.replacingOccurrences(of: "title:", with: ""))
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            let byline = [work.authors?.joined(separator: ", "), work.year.map(String.init), work.venue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !byline.isEmpty {
                Text(byline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !marks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(marks, id: \.self) { mark in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            MarkPill(mark: mark)
                            if !mark.meaning.isEmpty {
                                Text(mark.meaning)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let summary = work.summary, !summary.isEmpty {
                Text(summary).font(.body.weight(.medium))
            }
            if let abstract = work.abstract, !abstract.isEmpty {
                Text(abstract).textSelection(.enabled)
                if let source = work.abstractSource {
                    Text("Abstract via \(source)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let topics = live?.topics, !topics.isEmpty {
                Text("Topics: " + topics.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let byYear = live?.citationsByYear, !byYear.isEmpty {
                Text("Cited by year: " + byYear.prefix(6)
                    .map { "\(String($0.year)) \($0.count.formatted())" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let doi = work.doi, let url = URL(string: "https://doi.org/" + doi) {
                    Link("doi:\(doi)", destination: url)
                }
                if live?.isOpenAccess == true, let free = live?.openAccessURL,
                   let url = URL(string: free) {
                    Link("Read the free copy", destination: url)
                }
            }
            .font(.callout)
            let citing = (work.citedBy ?? []).compactMap { id in
                model.epubRecords.first { $0.id == id }
            }
            if !citing.isEmpty {
                Divider()
                Text(citing.count == 1 ? "Cited by 1 paper on your shelf"
                                       : "Cited by \(citing.count) papers on your shelf")
                    .font(.headline)
                ForEach(citing) { record in
                    Button {
                        // Opened where it cites the work, the passage
                        // flashing — the way a quote link lands.
                        if let place = Self.citingParagraph(in: record, of: work, key: key, model: model) {
                            model.openEPUB(address: record.id, fragment: place)
                        } else {
                            model.openEPUBRecord(withID: record.id)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.title)
                            Text(record.author).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Checked \(work.checked.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Library ▸ References' detail: a work's card under Title, Author and
/// Date; the Map of every citation under Map.
struct CitedWorksDetailPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("citedWorksSortKey") private var sortKey = "title"

    var body: some View {
        if sortKey == "map" {
            CitedWorksMapView()
        } else if let key = model.selectedCitedWorkKey {
            CitedWorkDetailView(key: key)
                .id(key)
        } else {
            ContentUnavailableView("No Reference Selected", systemImage: "quote.opening",
                                   description: Text("Choose a work to see everything known of it."))
        }
    }
}

/// Every citation in the library on one Map, as Author's Document Space
/// lays out the Library: the papers on the shelf are the documents — a
/// double-click opens one — and the works they cite stand among them as
/// pills, the way the Document Space draws its tags. Select a paper and
/// lines run to everything it cites; select a work and they run to every
/// paper citing it. A cited work the shelf holds is its paper, not a pill.
/// It is the reader's Map (ReaderMapView), so Select, Show, Layout, Views,
/// Gather, Z, Find and Ask AI are all there; moves are kept as the
/// reader's own, under one key for the library.
struct CitedWorksMapView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("citedWorksSortKey") private var sortKey = "title"
    @State private var built: CitationsMap?

    var body: some View {
        Group {
            if let built, !built.doc.concepts.isEmpty {
                ReaderMapView(doc: built.doc, extras: built.extras, bookKey: CitationsMap.key,
                              onShowInText: { _ in }, onClose: { sortKey = "title" },
                              onOpen: open,
                              focusID: model.selectedCitedWorkKey.flatMap { built.nodeForWork[$0] })
                    .id(built.stamp)
            } else if built != nil {
                ContentUnavailableView("No Citations to Map", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Check Library Now, in the master list, gathers every work your library cites."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await ReferenceStatus.adoptShared(from: model.index.folderURL)
            built = CitationsMap(works: ReferenceStatus.shared, records: model.epubRecords)
        }
    }

    /// A paper opens where the reader left it.
    private func open(_ id: String) {
        guard id.hasPrefix(CitationsMap.paperPrefix) else { return }
        model.openEPUBRecord(withID: String(id.dropFirst(CitationsMap.paperPrefix.count)))
    }
}

/// The library's citations as a Map's members: a concept per paper and per
/// cited work, each paper connected to what it cites, laid out to begin
/// with in Orbits — each paper with the works only it cites around it, the
/// works several cite standing on their own.
struct CitationsMap {
    static let key = "library-citations"
    static let paperPrefix = "paper:"
    static let workPrefix = "work:"

    var doc: LiquidDoc
    var extras = AuthoredMapExtras()
    /// The node each master-list key stands as: its pill, or its paper.
    var nodeForWork: [String: String] = [:]
    /// Changes when the members do, so the Map reads them afresh.
    var stamp = ""

    init(works all: [String: ReferenceStatus.CitedWork], records: [EPUBRecord]) {
        doc = LiquidDoc(format: LiquidDoc.knownFormat, id: Self.key,
                        title: "The Library\u{2019}s Citations", author: "",
                        created: .now, body: [], links: [], wraps: nil,
                        fileURL: FileManager.default.temporaryDirectory)
        // One entry per work: a work found by its title is kept under its
        // DOI as well, and stands once.
        let works = all.filter { key, work in
            guard key.hasPrefix("title:"), let doi = work.doi else { return true }
            return all[doi] == nil
        }
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recordsByDOI = Dictionary(records.compactMap { record in
            ReferenceStatus.cleanDOI(record.doi).map { ($0, record) }
        }, uniquingKeysWith: { first, _ in first })
        let recordsByTitle = Dictionary(records.compactMap { record -> (String, EPUBRecord)? in
            let folded = ReferenceStatus.normalizedTitle(record.title)
            return folded.count >= 12 ? (folded, record) : nil
        }, uniquingKeysWith: { first, _ in first })

        var connections: [String: Set<String>] = [:]
        var papers: [String: EPUBRecord] = [:]
        var citedTimes: [String: Int] = [:]
        var concepts: [LiquidDoc.Concept] = []
        var facts: [String: Shapes.Work] = [:]

        for (key, work) in works.sorted(by: { $0.key < $1.key }) {
            let citing = (work.citedBy ?? []).compactMap { recordsByID[$0] }
            guard !citing.isEmpty else { continue }
            // A work the shelf holds is its paper.
            let owned = ReferenceStatus.cleanDOI(work.doi).flatMap { recordsByDOI[$0] }
                ?? work.title.flatMap { recordsByTitle[ReferenceStatus.normalizedTitle($0)] }
            let node: String
            if let owned {
                node = Self.paperPrefix + owned.id
                papers[owned.id] = owned
            } else {
                node = Self.workPrefix + key
                concepts.append(.init(id: node, name: Self.label(of: work, key: key),
                                      description: Self.definition(of: work, key: key, citing: citing)))
                extras.pills.insert(node)
                facts[node] = Shapes.Work(work: work, key: key)
            }
            nodeForWork[key] = node
            citedTimes[node, default: 0] += citing.count
            for record in citing {
                papers[record.id] = record
                connections[Self.paperPrefix + record.id, default: []].insert(node)
            }
        }
        for record in papers.values.sorted(by: { $0.id < $1.id }) {
            let id = Self.paperPrefix + record.id
            let cites = connections[id]?.count ?? 0
            let citedBy = citedTimes[id] ?? 0
            let counts = [cites > 0 ? (cites == 1 ? "Cites 1 work" : "Cites \(cites) works") : nil,
                          citedBy > 0 ? (citedBy == 1 ? "cited by 1 paper on the shelf"
                                                      : "cited by \(citedBy) papers on the shelf") : nil]
                .compactMap { $0 }.joined(separator: ", ")
            let byline = [record.authorList.joined(separator: ", "), record.publication ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
            concepts.append(.init(id: id, name: Self.shortened(record.title, to: 48),
                                  description: [record.title, byline, counts + "."]
                                      .filter { !$0.isEmpty }.joined(separator: "\n")))
            extras.openable.insert(id)
        }

        doc.concepts = concepts
        extras.connections = connections
        extras.originalLayoutName = "Original Layout"
        extras.narrowing = ("Only Works Cited More Than Once",
                            Set(extras.pills.filter { (citedTimes[$0] ?? 0) < 2 }))

        var undirected = connections
        for (from, targets) in connections {
            for to in targets { undirected[to, default: []].insert(from) }
        }
        let nodes = concepts.map { ReaderMapNode(id: $0.id, name: $0.name, definition: $0.description, size: .zero) }
        let seeded = ReaderMapLayouts.analysis(.orbits, nodes: nodes, sections: [],
                                               dates: [:], categories: [:], links: undirected)
        doc.layouts = [LiquidDoc.Layout(index: 1, name: "Citations", positions: concepts.map { concept in
            let point = seeded[concept.id] ?? .zero
            return .init(id: concept.id, x: Double(point.x), y: Double(point.y), z: 0)
        }, sourceID: "citations")]
        stamp = "\(concepts.count)-\(connections.values.reduce(0) { $0 + $1.count })"
        let labels = Dictionary(concepts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        extras.shapes = Shapes(papers: papers.keys.map { Self.paperPrefix + $0 }, works: facts,
                               cites: connections, citedTimes: citedTimes, labels: labels).all
    }

    /// A pill's face, as a citation is written: the first author's surname
    /// and the year; failing an author, the title's opening words.
    static func label(of work: ReferenceStatus.CitedWork, key: String) -> String {
        let title = work.title ?? key.replacingOccurrences(of: "title:", with: "")
        guard let first = work.authors?.first, !first.isEmpty else {
            return shortened(title, to: 28)
        }
        let surname = first.contains(",") ? String(first.split(separator: ",")[0])
            : (first.split(separator: " ").last.map(String.init) ?? first)
        let more = (work.authors?.count ?? 0) > 1 ? " et al." : ""
        return surname + more + (work.year.map { " \($0)" } ?? "")
    }

    /// What the work's definition card says: its title, byline, gravest
    /// warning, and the papers that cite it.
    static func definition(of work: ReferenceStatus.CitedWork, key: String,
                           citing: [EPUBRecord]) -> String {
        let title = work.title ?? key.replacingOccurrences(of: "title:", with: "")
        let byline = [work.authors?.joined(separator: ", "), work.year.map(String.init), work.venue]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        let warning = ReferenceStatus.standingWarning(doi: work.doi, title: title, year: work.year)
            .map { $0.detail.isEmpty ? $0.text : "\($0.text): \($0.detail)" }
        let cited = (citing.count == 1 ? "Cited by 1 paper on the shelf: "
                                       : "Cited by \(citing.count) papers on the shelf: ")
            + citing.map(\.title).sorted().joined(separator: "; ") + "."
        return [title, byline, warning, cited].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func shortened(_ text: String, to length: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > length ? String(trimmed.prefix(length - 1)) + "\u{2026}" : trimmed
    }
}

// MARK: - Shapes of citation

/// The Shapes list for the library's citations: nine ways of seeing
/// so many references, after Doug Engelbart, Ted Nelson and Frode
/// Hegland. Each is a pure arrangement of the members — papers and cited
/// works — with its groups captioned. Positions are Author's canvas
/// points: centres, y down; the Map fits whatever is chosen into view.
struct Shapes {
    /// What a shape needs to know of one cited work.
    struct Work {
        var year: Int?
        var topic: String?
        var open: Bool
        var trust: Int

        init(work: ReferenceStatus.CitedWork, key: String) {
            year = work.year
            topic = work.live?.topics?.first
            open = work.live?.isOpenAccess == true
            trust = Shapes.trustRow(work, key: key)
        }
    }

    let papers: [String]
    let works: [String: Work]
    let cites: [String: Set<String>]
    let citedTimes: [String: Int]
    let labels: [String: String]

    // Pitches: a pill's column, a paper's (its title is longer), a row.
    private static let pillPitch: CGFloat = 240
    private static let paperPitch: CGFloat = 420
    private static let rowPitch: CGFloat = 36
    private static let captionGap: CGFloat = 56

    private static let engelbart = "Doug Engelbart \u{2014} augmenting the community"
    private static let nelson = "Ted Nelson \u{2014} intertwingularity"
    private static let hegland = "Frode Hegland \u{2014} visible, liquid information"

    init(papers: [String], works: [String: Work], cites: [String: Set<String>],
         citedTimes: [String: Int], labels: [String: String]) {
        self.works = works
        self.cites = cites
        self.citedTimes = citedTimes
        self.labels = labels
        // The papers in an order that keeps those citing the same works
        // beside each other: each next the one sharing most with the last.
        var left = Set(papers)
        var ordered: [String] = []
        var current = papers.max { (cites[$0]?.count ?? 0, $1) < (cites[$1]?.count ?? 0, $0) }
        while let paper = current {
            ordered.append(paper)
            left.remove(paper)
            let mine = cites[paper] ?? []
            current = left.max { a, b in
                let sa = (cites[a] ?? []).intersection(mine).count
                let sb = (cites[b] ?? []).intersection(mine).count
                return sa != sb ? sa < sb : a > b
            }
        }
        self.papers = ordered
    }

    var all: [MapShape] {
        [commonGround, outline, bootstrapping,
         intertwingled, parallel, throughTime,
         trust, reach, topics]
    }

    // MARK: Engelbart

    /// What the community holds in common rises to the top.
    private var commonGround: MapShape {
        var place = Placement()
        var y = place.rows("Your shelf", ids: papers, perRow: 8, pitch: Self.paperPitch, top: 0)
        let bands: [(String, ClosedRange<Int>)] = [("Cited by 5 or more of your papers", 5...Int.max),
                                                   ("Cited by 3 or 4", 3...4),
                                                   ("Cited by 2", 2...2),
                                                   ("Cited by 1", 1...1)]
        for (title, range) in bands {
            y = place.rows(title, ids: byCiters(pills.filter { range.contains(citedTimes[$0] ?? 0) }),
                           perRow: 14, pitch: Self.pillPitch, top: y)
        }
        return MapShape(group: Self.engelbart, title: "Common Ground",
                        explanation: "The community\u{2019}s shared knowledge, as in Engelbart\u{2019}s Dynamic Knowledge Repository: the works many of your papers stand on rise to the top.",
                        positions: place.positions, captions: place.captions)
    }

    /// An NLS view specification: each paper a heading, its references
    /// beneath it as an outline.
    private var outline: MapShape {
        var place = Placement()
        var claimed = Set<String>()
        let ordered = papers.sorted { (cites[$0]?.count ?? 0, $1) > (cites[$1]?.count ?? 0, $0) }
        var top: CGFloat = 0
        for rowStart in stride(from: 0, to: ordered.count, by: 10) {
            var deepest: CGFloat = 0
            for (column, paper) in ordered[rowStart..<min(rowStart + 10, ordered.count)].enumerated() {
                let x = CGFloat(column) * Self.paperPitch
                place.positions[paper] = CGPoint(x: x, y: top)
                let own = byLabel((cites[paper] ?? []).filter { works[$0] != nil && !claimed.contains($0) })
                claimed.formUnion(own)
                for (index, work) in own.enumerated() {
                    place.positions[work] = CGPoint(x: x + 30, y: top + 44 + CGFloat(index) * Self.rowPitch)
                }
                deepest = max(deepest, 44 + CGFloat(own.count) * Self.rowPitch)
            }
            top += deepest + Self.captionGap
        }
        return MapShape(group: Self.engelbart, title: "Outline",
                        explanation: "An NLS view specification: the same structure seen another way \u{2014} each paper a heading, the works it cites listed beneath it. A work several cite stands under the first; its lines find the rest.",
                        positions: place.positions)
    }

    /// Engelbart's A, B and C activities, read in the citations.
    private var bootstrapping: MapShape {
        var place = Placement()
        let cBand = papers.filter { (citedTimes[$0] ?? 0) > 0 }
        let bBand = papers.filter { (citedTimes[$0] ?? 0) == 0 }
        var y = place.rows("C \u{2014} papers your shelf itself builds on", ids: cBand, perRow: 6,
                           pitch: Self.paperPitch, top: 0)
        y = place.rows("B \u{2014} the papers improving on the work", ids: bBand, perRow: 8,
                       pitch: Self.paperPitch, top: y)
        _ = place.rows("A \u{2014} the works they build on", ids: byCiters(pills), perRow: 14,
                       pitch: Self.pillPitch, top: y)
        return MapShape(group: Self.engelbart, title: "Bootstrapping",
                        explanation: "Engelbart\u{2019}s ABC: A, the work itself; B, improving it \u{2014} the papers citing it; C, improving how we improve \u{2014} papers your shelf cites among its own.",
                        positions: place.positions, captions: place.captions)
    }

    // MARK: Nelson

    /// Shared works hang between the papers citing them; each paper's own
    /// references fall beneath it.
    private var intertwingled: MapShape {
        var place = Placement()
        let pitch: CGFloat = 230
        var paperX: [String: CGFloat] = [:]
        for (index, paper) in papers.enumerated() {
            let x = CGFloat(index) * pitch
            paperX[paper] = x
            // Two staggered lines, so long titles do not overlap.
            place.positions[paper] = CGPoint(x: x, y: index.isMultiple(of: 2) ? 0 : -44)
        }
        let shared = byCiters(pills.filter { (citedTimes[$0] ?? 0) >= 2 })
        var stacks: [Int: Int] = [:]
        var sharedDepth: CGFloat = 0
        for work in shared {
            let xs = citers(of: work).compactMap { paperX[$0] }
            guard !xs.isEmpty else { continue }
            let slot = Int((Self.mean(xs) / Self.pillPitch).rounded())
            let level = stacks[slot, default: 0]
            stacks[slot] = level + 1
            let y = 90 + CGFloat(level) * Self.rowPitch
            place.positions[work] = CGPoint(x: CGFloat(slot) * Self.pillPitch, y: y)
            sharedDepth = max(sharedDepth, y)
        }
        let singleTop = sharedDepth + 120
        for paper in papers {
            let own = byLabel((cites[paper] ?? []).filter { works[$0] != nil && (citedTimes[$0] ?? 0) < 2 })
            for (index, work) in own.enumerated() {
                place.positions[work] = CGPoint(x: paperX[paper] ?? 0,
                                                y: singleTop + CGFloat(index) * Self.rowPitch)
            }
        }
        place.captions = [.init(title: "Shared \u{2014} between the papers citing them", point: CGPoint(x: -380, y: 90)),
                          .init(title: "Each paper\u{2019}s own", point: CGPoint(x: -380, y: singleTop))]
        return MapShape(group: Self.nelson, title: "Intertwingled",
                        explanation: "\u{201C}Everything is deeply intertwingled\u{201D}: each work several papers cite hangs between them, where their lines cross; each paper\u{2019}s own references fall beneath it.",
                        positions: place.positions, captions: place.captions)
    }

    /// Nelson's parallel documents: the papers in two facing columns, the
    /// works they share in the gutter between.
    private var parallel: MapShape {
        var place = Placement()
        let half = (papers.count + 1) / 2
        let columnX: CGFloat = 560
        var paperY: [String: CGFloat] = [:]
        var cursor: [CGFloat] = [0, 0]
        for (index, paper) in papers.enumerated() {
            let side = index < half ? 0 : 1
            let x = side == 0 ? -columnX : columnX
            let y = cursor[side]
            place.positions[paper] = CGPoint(x: x, y: y)
            paperY[paper] = y
            // Its own references fan outward, five to a line.
            let own = byLabel((cites[paper] ?? []).filter { works[$0] != nil && (citedTimes[$0] ?? 0) < 2 })
            for (n, work) in own.enumerated() {
                let out = CGFloat(n % 5 + 1) * Self.pillPitch + 140
                place.positions[work] = CGPoint(x: side == 0 ? x - out : x + out,
                                                y: y + CGFloat(n / 5) * Self.rowPitch)
            }
            cursor[side] = y + max(60, CGFloat((own.count + 4) / 5) * Self.rowPitch + 24)
        }
        // The gutter: each shared work level with the middle of its
        // citers, two abreast, moved down until it finds room.
        var taken = Set<String>()
        let gutter: [CGFloat] = [-Self.pillPitch / 2, Self.pillPitch / 2]
        var shared: [(work: String, y: CGFloat)] = []
        for work in pills where (citedTimes[work] ?? 0) >= 2 {
            shared.append((work, Self.mean(citers(of: work).compactMap { paperY[$0] })))
        }
        shared.sort { a, b in a.y != b.y ? a.y < b.y : a.work < b.work }
        for (work, target) in shared {
            var row = Int((target / Self.rowPitch).rounded())
            while true {
                if let column = (0..<2).first(where: { !taken.contains("\(row):\($0)") }) {
                    taken.insert("\(row):\(column)")
                    place.positions[work] = CGPoint(x: gutter[column], y: CGFloat(row) * Self.rowPitch)
                    break
                }
                row += 1
            }
        }
        place.captions = [.init(title: "Shared", point: CGPoint(x: 0, y: -70))]
        return MapShape(group: Self.nelson, title: "Parallel Columns",
                        explanation: "Side by side, as Nelson\u{2019}s parallel documents and transpointing windows: the papers in two facing columns, the works they share in the gutter between, each paper\u{2019}s own reaching outward.",
                        positions: place.positions, captions: place.captions)
    }

    /// Origins kept visible: the cited works by when they appeared.
    private var throughTime: MapShape {
        var place = Placement()
        func bucket(_ year: Int?) -> (Int, String) {
            guard let year else { return (Int.max, "Year unknown") }
            if year < 1950 { return (0, "Before 1950") }
            if year < 2010 { return (year / 10 * 10, "\(year / 10 * 10)s") }
            return (year, String(year))
        }
        var groups: [Int: (String, [String])] = [:]
        for work in pills {
            let (key, title) = bucket(works[work]?.year)
            groups[key, default: (title, [])].1.append(work)
        }
        var x: CGFloat = 0
        for key in groups.keys.sorted() {
            guard let (title, members) = groups[key] else { continue }
            x = place.columns(title, ids: byCiters(members), perColumn: 30, pitch: Self.pillPitch, left: x)
        }
        _ = place.columns("Your shelf \u{2014} the present", ids: papers, perColumn: 40,
                          pitch: Self.paperPitch, left: x + 140)
        return MapShape(group: Self.nelson, title: "Through Time",
                        explanation: "Origins kept in view, as Xanadu keeps every quotation joined to where it came from: the cited works by the year they appeared, oldest at the left, your shelf at the right as the present.",
                        positions: place.positions, captions: place.captions)
    }

    // MARK: Hegland

    private static let trustTitles = ["Retracted, withdrawn or not replicated",
                                      "Expression of concern, or replication mixed",
                                      "Contradicted by some citing work (scite)",
                                      "Corrected, or not verified",
                                      "Preprint, or a newer version exists",
                                      "Replicated",
                                      "No standing mark"]

    /// Which Trust row a work stands in: its gravest mark, as the
    /// References keywords give them.
    static func trustRow(_ work: ReferenceStatus.CitedWork, key: String) -> Int {
        let title = work.title ?? key.replacingOccurrences(of: "title:", with: "")
        let marks = ReferenceStatus.marks(for: .init(doi: work.doi, title: title, year: work.year))
            .filter(\.pill)
        if marks.contains(where: { $0.tone == .alarm }) { return 0 }
        if marks.contains(where: { $0.tone == .caution }) { return 1 }
        if (work.live?.sciteContradicting ?? 0) > 0 { return 2 }
        if marks.contains(where: { $0.tone == .quiet }) { return 3 }
        if marks.contains(where: { $0.tone == .info }) { return 4 }
        if marks.contains(where: { $0.tone == .good }) { return 5 }
        return 6
    }

    /// What the references stand on, gravest first.
    private var trust: MapShape {
        var place = Placement()
        var y: CGFloat = 0
        for (row, title) in Self.trustTitles.enumerated() {
            y = place.rows(title, ids: byCiters(pills.filter { works[$0]?.trust == row }),
                           perRow: 14, pitch: Self.pillPitch, top: y)
        }
        _ = place.rows("Your shelf", ids: papers, perRow: 8, pitch: Self.paperPitch, top: y)
        return MapShape(group: Self.hegland, title: "Trust",
                        explanation: "The References keywords as rows: what is retracted, questioned or contradicted stands first, so nothing rests unseen on a weak source.",
                        positions: place.positions, captions: place.captions)
    }

    /// Information you can reach: owned, open, or closed.
    private var reach: MapShape {
        var place = Placement()
        var y = place.rows("On your shelf", ids: papers, perRow: 8, pitch: Self.paperPitch, top: 0)
        y = place.rows("Open \u{2014} a free copy to read", ids: byCiters(pills.filter { works[$0]?.open == true }),
                       perRow: 14, pitch: Self.pillPitch, top: y)
        _ = place.rows("Closed, or not known to be open", ids: byCiters(pills.filter { works[$0]?.open != true }),
                       perRow: 14, pitch: Self.pillPitch, top: y)
        return MapShape(group: Self.hegland, title: "Reach",
                        explanation: "Liquid information is information you can reach and work with: what is on your shelf, what is open to read, and what is closed.",
                        positions: place.positions, captions: place.captions)
    }

    /// Knowledge Space clusters, by topic.
    private var topics: MapShape {
        var place = Placement()
        var byTopic: [String: [String]] = [:]
        for work in pills { byTopic[works[work]?.topic ?? "", default: []].append(work) }
        let named = byTopic.filter { !$0.key.isEmpty && $0.value.count >= 4 }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        let other = byTopic.filter { !$0.key.isEmpty && $0.value.count < 4 }.flatMap(\.value)
        let top = place.rows("Your shelf", ids: papers, perRow: 8, pitch: Self.paperPitch, top: 0) + 40
        var x: CGFloat = 0
        for (topic, members) in named {
            x = place.columns(topic, ids: byCiters(members), perColumn: 24, pitch: Self.pillPitch,
                              left: x, top: top)
        }
        x = place.columns("Other topics", ids: byCiters(other), perColumn: 24, pitch: Self.pillPitch,
                          left: x, top: top)
        _ = place.columns("No topic known", ids: byCiters(byTopic[""] ?? []), perColumn: 24,
                          pitch: Self.pillPitch, left: x, top: top)
        return MapShape(group: Self.hegland, title: "Topics",
                        explanation: "As a Knowledge Space gathers its concepts: the cited works under their first OpenAlex topic, the largest topic first.",
                        positions: place.positions, captions: place.captions)
    }

    // MARK: Helpers

    private var pills: [String] { Array(works.keys) }

    private static func mean(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        var total: CGFloat = 0
        for value in values { total += value }
        return total / CGFloat(values.count)
    }

    private func citers(of work: String) -> [String] {
        papers.filter { cites[$0]?.contains(work) == true }
    }

    /// Most-cited first, then by label.
    private func byCiters(_ ids: [String]) -> [String] {
        ids.sorted {
            let a = citedTimes[$0] ?? 0, b = citedTimes[$1] ?? 0
            return a != b ? a > b : (labels[$0] ?? $0) < (labels[$1] ?? $1)
        }
    }

    private func byLabel<S: Sequence>(_ ids: S) -> [String] where S.Element == String {
        ids.sorted { (labels[$0] ?? $0).localizedCaseInsensitiveCompare(labels[$1] ?? $1) == .orderedAscending }
    }

    /// Lays groups out as captioned blocks.
    private struct Placement {
        var positions: [String: CGPoint] = [:]
        var captions: [MapShape.Caption] = []

        /// A band across: the caption, then the members wrapping `perRow`
        /// to a line. Returns where the next band starts.
        mutating func rows(_ title: String, ids: [String], perRow: Int, pitch: CGFloat,
                           top: CGFloat) -> CGFloat {
            guard !ids.isEmpty else { return top }
            let width = CGFloat(min(ids.count, perRow) - 1) * pitch
            captions.append(.init(title: "\(title) (\(ids.count))", point: CGPoint(x: width / 2, y: top)))
            for (index, id) in ids.enumerated() {
                positions[id] = CGPoint(x: CGFloat(index % perRow) * pitch,
                                        y: top + Shapes.captionGap + CGFloat(index / perRow) * Shapes.rowPitch)
            }
            let lines = (ids.count + perRow - 1) / perRow
            return top + Shapes.captionGap + CGFloat(lines) * Shapes.rowPitch + Shapes.captionGap
        }

        /// A group down: the caption, then the members in columns of
        /// `perColumn`. Returns where the next group starts.
        mutating func columns(_ title: String, ids: [String], perColumn: Int, pitch: CGFloat,
                              left: CGFloat, top: CGFloat = 0) -> CGFloat {
            guard !ids.isEmpty else { return left }
            let count = (ids.count + perColumn - 1) / perColumn
            let width = CGFloat(count - 1) * pitch
            captions.append(.init(title: "\(title) (\(ids.count))", point: CGPoint(x: left + width / 2, y: top)))
            for (index, id) in ids.enumerated() {
                positions[id] = CGPoint(x: left + CGFloat(index / perColumn) * pitch,
                                        y: top + Shapes.captionGap + CGFloat(index % perColumn) * Shapes.rowPitch)
            }
            return left + width + pitch + 60
        }
    }
}
