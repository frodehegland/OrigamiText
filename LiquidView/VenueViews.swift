import SwiftUI

// Venue relation views: how one proceedings' papers relate to each
// other, shown inside the venue's own page (Library ▸ Journals ▸ venue).
// Three views, each an established bibliometric idiom adapted to what
// the shelf actually knows:
//
// - Shared Ground: bibliographic coupling (Kessler 1963) — two papers
//   relate when they cite the same works. Drawn as an arc diagram, not
//   a force graph: at proceedings density a node-link view is a
//   hairball; arcs over a seriated list stay readable.
// - Roots: Reference Publication Year Spectroscopy (Marx, Bornmann,
//   Barth & Leydesdorff 2014) — the venue's cited references by their
//   publication year, peaks marking the field's historical roots, with
//   the canon (works several papers cite) ranked beneath.
// - Threads: topic co-occurrence in the VOSviewer tradition — the
//   venue's AI topic analysis when it has run, title terms otherwise,
//   each thread unfolding to its papers.

// MARK: - The relations engine

/// Derives every cross-paper relation from the venue's documents. Pure
/// and off-main-thread friendly: records and references in, analysis out.
nonisolated enum VenueRelations {

    struct Paper: Identifiable, Sendable, Hashable {
        let id: String        // EPUBRecord.id
        let title: String
        let author: String
    }

    /// One cited work, identified by DOI when it has one, by its
    /// normalised title otherwise — the same work cited with different
    /// BibTeX keys in different papers still counts once.
    struct CitedWork: Identifiable, Sendable {
        let key: String
        let display: String
        let year: Int?
        var citedBy: [String] = []   // paper (record) ids, in venue order
        var id: String { key }
    }

    /// Two papers and the works both cite.
    struct Coupling: Identifiable, Sendable {
        let a: String
        let b: String
        let sharedKeys: [String]
        var id: String { a + "\u{2194}" + b }
        var weight: Int { sharedKeys.count }
    }

    struct Analysis: Sendable {
        var papers: [Paper] = []                 // seriated: coupled papers adjacent
        var couplings: [Coupling] = []
        var canon: [CitedWork] = []              // cited by ≥ 2 papers, most first
        var workByKey: [String: CitedWork] = [:]
        var yearCounts: [(year: Int, count: Int)] = []
        var referenceCount = 0

        func couplings(with paperID: String) -> [Coupling] {
            couplings.filter { $0.a == paperID || $0.b == paperID }
                .sorted { $0.weight > $1.weight }
        }
    }

    static func analyze(records: [(id: String, title: String, author: String,
                                   references: [LiquidDoc.Reference])]) -> Analysis {
        var analysis = Analysis()
        var citedKeys: [String: Set<String>] = [:]   // paper id → work keys
        var works: [String: CitedWork] = [:]

        for record in records {
            var keys: Set<String> = []
            for reference in record.references {
                guard let entry = BibTeXParser.parse(reference.bibtex).first else { continue }
                let key = workKey(for: entry)
                guard !key.isEmpty else { continue }
                keys.insert(key)
                analysis.referenceCount += 1
                if var work = works[key] {
                    if !work.citedBy.contains(record.id) { work.citedBy.append(record.id) }
                    works[key] = work
                } else {
                    works[key] = CitedWork(key: key,
                                           display: display(for: entry),
                                           year: entry.year.flatMap { Int($0.prefix(4)) },
                                           citedBy: [record.id])
                }
            }
            citedKeys[record.id] = keys
        }

        // Couplings between every pair sharing at least one work. In a
        // narrow field one shared reference couples nearly everything
        // (the Tethne caution), so the views threshold what they draw.
        for i in records.indices {
            for j in records.indices where j > i {
                let shared = citedKeys[records[i].id, default: []]
                    .intersection(citedKeys[records[j].id, default: []])
                guard !shared.isEmpty else { continue }
                analysis.couplings.append(Coupling(a: records[i].id, b: records[j].id,
                                                   sharedKeys: shared.sorted()))
            }
        }

        // Seriation: nearest-neighbour chain, so strongly coupled papers
        // sit adjacent and their arcs stay short.
        var weight: [String: [String: Int]] = [:]
        for coupling in analysis.couplings {
            weight[coupling.a, default: [:]][coupling.b] = coupling.weight
            weight[coupling.b, default: [:]][coupling.a] = coupling.weight
        }
        // Spelled out step by step: tuple-comparison one-liners here sent
        // an archive machine's compiler into type-check timeout.
        func totalWeight(_ id: String) -> Int {
            weight[id]?.values.reduce(0, +) ?? 0
        }
        var remaining = records.map {
            Paper(id: $0.id, title: $0.title, author: $0.author)
        }
        var ordered: [Paper] = []
        var current = remaining.max { totalWeight($0.id) < totalWeight($1.id) }
        while let paper = current {
            ordered.append(paper)
            remaining.removeAll { $0.id == paper.id }
            current = remaining.max { lhs, rhs in
                let leftNear = weight[paper.id]?[lhs.id] ?? 0
                let rightNear = weight[paper.id]?[rhs.id] ?? 0
                if leftNear != rightNear { return leftNear < rightNear }
                return totalWeight(lhs.id) < totalWeight(rhs.id)
            }
        }
        analysis.papers = ordered

        analysis.workByKey = works
        analysis.canon = works.values.filter { $0.citedBy.count >= 2 }
            .sorted { lhs, rhs in
                if lhs.citedBy.count != rhs.citedBy.count {
                    return lhs.citedBy.count > rhs.citedBy.count
                }
                return (lhs.year ?? 0) < (rhs.year ?? 0)
            }

        var years: [Int: Int] = [:]
        for work in works.values {
            if let year = work.year, year > 1400, year <= 2100 { years[year, default: 0] += 1 }
        }
        analysis.yearCounts = years.sorted { $0.key < $1.key }
            .map { (year: $0.key, count: $0.value) }
        return analysis
    }

    /// DOI when the record has one; the normalised title otherwise.
    private static func workKey(for entry: BibTeXEntry) -> String {
        if let doi = entry.fields["doi"]?.lowercased()
            .replacingOccurrences(of: "https://doi.org/", with: "")
            .trimmingCharacters(in: .whitespaces), !doi.isEmpty {
            return "doi:" + doi
        }
        let title = (entry.title ?? "").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return title.isEmpty ? "" : "title:" + title
    }

    private static func display(for entry: BibTeXEntry) -> String {
        var parts: [String] = []
        if let author = entry.firstAuthor { parts.append(author) }
        if let year = entry.year { parts.append("(\(year))") }
        if let title = entry.title { parts.append(title) }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? "Untitled" : joined
    }
}

// MARK: - The venue view switcher

enum VenueViewMode: String, CaseIterable, Identifiable {
    case documents = "Documents"
    case sharedGround = "Shared Ground"
    case roots = "Roots"
    case threads = "Threads"
    var id: String { rawValue }
}

/// Loads the venue's analysis once and serves whichever relation view
/// is chosen. The venue page owns the mode picker.
struct VenueRelationsHost: View {
    @Environment(AppModel.self) private var model
    let venue: String
    let mode: VenueViewMode
    @State private var analysis: VenueRelations.Analysis?

    var body: some View {
        Group {
            if let analysis {
                switch mode {
                case .documents:
                    EmptyView()
                case .sharedGround:
                    VenueSharedGroundView(venue: venue, analysis: analysis)
                case .roots:
                    VenueRootsView(venue: venue, analysis: analysis)
                case .threads:
                    VenueThreadsView(venue: venue, analysis: analysis)
                }
            } else {
                ProgressView("Reading the venue\u{2019}s references\u{2026}")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: venue) {
            let inputs = model.epubRecords(inPublication: venue).map { record in
                (id: record.id, title: record.title, author: record.author,
                 references: model.index.byID[record.id]?.doc.references ?? [])
            }
            analysis = await Task.detached(priority: .userInitiated) {
                VenueRelations.analyze(records: inputs)
            }.value
        }
    }
}

// MARK: - Shared Ground (bibliographic coupling arcs)

/// The venue's papers in one seriated column, arcs in the left gutter
/// joining every pair that cites common works. Select a paper for its
/// partners and the works they stand on together.
struct VenueSharedGroundView: View {
    @Environment(AppModel.self) private var model
    let venue: String
    let analysis: VenueRelations.Analysis
    @State private var selectedID: String?

    private let rowHeight: CGFloat = 24
    private let gutter: CGFloat = 96

    /// One shared reference couples nearly everything in a narrow
    /// field; the drawing threshold climbs until the view stays legible.
    private var drawThreshold: Int {
        for threshold in 1...6 where analysis.couplings.filter({ $0.weight >= threshold }).count <= 240 {
            return threshold
        }
        return 7
    }

    var body: some View {
        let threshold = drawThreshold
        let drawn = analysis.couplings.filter { $0.weight >= threshold }
        HSplitView {
            ScrollView {
                paperColumn(drawn: drawn, threshold: threshold)
                    .padding(.vertical, 10)
            }
            .frame(minWidth: 380)
            detailPanel
                .frame(minWidth: 240)
        }
        .overlay(alignment: .bottomLeading) {
            Text(threshold > 1
                 ? "Arcs: \(drawn.count) pairs sharing \u{2265}\(threshold) references (of \(analysis.couplings.count) coupled pairs)"
                 : "Arcs: \(drawn.count) coupled pairs")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(6)
        }
    }

    private func paperColumn(drawn: [VenueRelations.Coupling], threshold: Int) -> some View {
        let papers = analysis.papers
        let indexByID = Dictionary(uniqueKeysWithValues:
            papers.enumerated().map { ($0.element.id, $0.offset) })
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for coupling in drawn {
                    guard let rowA = indexByID[coupling.a],
                          let rowB = indexByID[coupling.b] else { continue }
                    let yA = CGFloat(rowA) * rowHeight + rowHeight / 2
                    let yB = CGFloat(rowB) * rowHeight + rowHeight / 2
                    let selected = selectedID == nil
                        || coupling.a == selectedID || coupling.b == selectedID
                    let span = abs(yA - yB)
                    let reach = min(gutter - 8, 14 + span * 0.12 + CGFloat(coupling.weight) * 3)
                    var path = Path()
                    path.move(to: CGPoint(x: gutter - 2, y: yA))
                    path.addQuadCurve(to: CGPoint(x: gutter - 2, y: yB),
                                      control: CGPoint(x: gutter - 2 - reach, y: (yA + yB) / 2))
                    context.stroke(path,
                                   with: .color(.accentColor.opacity(selected ? 0.55 : 0.08)),
                                   lineWidth: min(0.6 + CGFloat(coupling.weight) * 0.4, 4))
                }
            }
            .frame(height: CGFloat(papers.count) * rowHeight)
            VStack(spacing: 0) {
                ForEach(papers) { paper in
                    Button {
                        selectedID = selectedID == paper.id ? nil : paper.id
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(paper.id == selectedID
                                      ? Color.accentColor : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(paper.title)
                                .lineLimit(1)
                                .font(.callout)
                                .foregroundStyle(paper.id == selectedID ? .primary : .secondary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(height: rowHeight)
                }
            }
            .padding(.leading, gutter)
        }
    }

    @ViewBuilder private var detailPanel: some View {
        if let selectedID,
           let paper = analysis.papers.first(where: { $0.id == selectedID }) {
            let partners = analysis.couplings(with: selectedID)
            List {
                Section {
                    ForEach(partners) { coupling in
                        let otherID = coupling.a == selectedID ? coupling.b : coupling.a
                        if let other = analysis.papers.first(where: { $0.id == otherID }) {
                            DisclosureGroup {
                                ForEach(coupling.sharedKeys, id: \.self) { key in
                                    if let work = analysis.workByKey[key] {
                                        Text(work.display)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(other.title).lineLimit(2)
                                    Spacer()
                                    Text("\(coupling.weight)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paper.title).font(.headline).lineLimit(3)
                        Text("Shares references with \(partners.count) paper\(partners.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open") { model.openEPUBRecord(withID: paper.id) }
                            .font(.caption)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Shared Ground", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Papers that cite the same works are joined by arcs. Select a paper to see whom it shares its ground with, and on which works they stand.")
            }
        }
    }
}

// MARK: - Roots (reference publication year spectroscopy)

/// When was the literature this venue stands on written? The spectrum's
/// peaks are the field's roots; the canon beneath ranks the works
/// several papers cite.
struct VenueRootsView: View {
    @Environment(AppModel.self) private var model
    let venue: String
    let analysis: VenueRelations.Analysis
    @State private var selectedYear: Int?

    var body: some View {
        List {
            Section("Cited literature by year — \(analysis.referenceCount) references") {
                spectrum
                    .frame(height: 120)
                    .listRowSeparator(.hidden)
                if let selectedYear {
                    let works = analysis.workByKey.values
                        .filter { $0.year == selectedYear }
                        .sorted { $0.citedBy.count > $1.citedBy.count }
                    Section {
                        ForEach(works.prefix(12)) { work in
                            HStack(alignment: .firstTextBaseline) {
                                Text(work.display).font(.caption)
                                Spacer()
                                Text("\(work.citedBy.count)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(String(selectedYear))
                    }
                }
            }
            Section("The canon — works several papers stand on") {
                if analysis.canon.isEmpty {
                    Text("No work here is cited by more than one paper.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(analysis.canon.prefix(40)) { work in
                        DisclosureGroup {
                            ForEach(work.citedBy, id: \.self) { paperID in
                                if let paper = analysis.papers.first(where: { $0.id == paperID }) {
                                    Button {
                                        model.openEPUBRecord(withID: paperID)
                                    } label: {
                                        Text(paper.title).font(.caption).lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(work.display).lineLimit(2)
                                Spacer()
                                Text("\(work.citedBy.count) papers")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var spectrum: some View {
        let counts = analysis.yearCounts
        let maxCount = counts.map(\.count).max() ?? 1
        return GeometryReader { geo in
            let years = (counts.first?.year ?? 2000)...(counts.last?.year ?? 2026)
            let span = max(years.count, 1)
            let barWidth = max(geo.size.width / CGFloat(span) - 1, 2)
            let byYear = Dictionary(uniqueKeysWithValues: counts.map { ($0.year, $0.count) })
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(years), id: \.self) { year in
                    let count = byYear[year] ?? 0
                    VStack(spacing: 2) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(year == selectedYear ? Color.accentColor
                                  : Color.accentColor.opacity(0.45))
                            .frame(width: barWidth,
                                   height: max(CGFloat(count) / CGFloat(maxCount) * 88, count > 0 ? 2 : 0))
                        Text(year % 10 == 0 ? String(year) : " ")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: barWidth)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedYear = selectedYear == year ? nil : year
                    }
                    .help(count > 0 ? "\(year): \(count) cited works" : String(year))
                }
            }
        }
    }
}

// MARK: - Threads (topic co-occurrence)

/// The venue's themes as threads through its papers: the AI topic
/// analysis where it has run, significant title terms otherwise.
struct VenueThreadsView: View {
    @Environment(AppModel.self) private var model
    let venue: String
    let analysis: VenueRelations.Analysis

    private struct Thread: Identifiable {
        let name: String
        let paperIDs: [String]
        var id: String { name }
    }

    private var threads: [Thread] {
        // The AI analysis, when the venue has one.
        if let paperTopics = model.publicationAnalyses[venue]?.paperTopics,
           !paperTopics.isEmpty {
            var byTopic: [String: [String]] = [:]
            for (paperID, topics) in paperTopics {
                for topic in topics {
                    let name = topic.lowercased()
                    byTopic[name, default: []].append(paperID)
                }
            }
            return byTopic.filter { $0.value.count >= 2 }
                .map { Thread(name: $0.key, paperIDs: $0.value.sorted()) }
                .sorted { lhs, rhs in
                    if lhs.paperIDs.count != rhs.paperIDs.count {
                        return lhs.paperIDs.count > rhs.paperIDs.count
                    }
                    return lhs.name < rhs.name
                }
        }
        // Title terms otherwise: words at least two papers share.
        let stop: Set<String> = ["a", "an", "the", "of", "and", "for", "in", "on",
                                 "with", "to", "as", "its", "from", "by", "at", "or",
                                 "is", "are", "how", "what", "via", "using", "towards",
                                 "toward", "beyond", "do", "you", "not", "new"]
        var byTerm: [String: Set<String>] = [:]
        for paper in analysis.papers {
            let words = paper.title.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count > 3 && !stop.contains($0) }
            for word in Set(words) {
                byTerm[word, default: []].insert(paper.id)
            }
        }
        return byTerm.filter { $0.value.count >= 2 }
            .map { Thread(name: $0.key, paperIDs: $0.value.sorted()) }
            .sorted { lhs, rhs in
                    if lhs.paperIDs.count != rhs.paperIDs.count {
                        return lhs.paperIDs.count > rhs.paperIDs.count
                    }
                    return lhs.name < rhs.name
                }
    }

    /// Extraction categories aggregated across the venue: every item and
    /// the papers that carry it (see EntityExtraction.swift).
    private var extractionSections: [(category: String, threads: [Thread])] {
        var perCategory: [String: [String: [String]]] = [:]   // category → item → paper ids
        var order: [String] = []
        for paper in analysis.papers {
            guard let extraction = model.documentExtractions[paper.id] else { continue }
            for (category, items) in extraction.categories {
                if !order.contains(category) { order.append(category) }
                for item in items {
                    perCategory[category, default: [:]][item, default: []].append(paper.id)
                }
            }
        }
        return order.compactMap { category in
            guard let items = perCategory[category] else { return nil }
            let threads = items.map { Thread(name: $0.key, paperIDs: $0.value.sorted()) }
                .sorted { lhs, rhs in
                    if lhs.paperIDs.count != rhs.paperIDs.count {
                        return lhs.paperIDs.count > rhs.paperIDs.count
                    }
                    return lhs.name < rhs.name
                }
            return (category, threads)
        }
    }

    var body: some View {
        let threads = threads
        let usesAI = !(model.publicationAnalyses[venue]?.paperTopics.isEmpty ?? true)
        let extracted = analysis.papers.filter {
            model.documentExtractions[$0.id]?.isEmpty == false
        }.count
        List {
            Section {
                HStack {
                    if extracted > 0 {
                        Text("\(extracted) of \(analysis.papers.count) papers read for concepts and entities.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Read every paper for concepts, keywords, people, places, technologies, and scientific terms — on this Mac\u{2019}s model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let progress = model.extractionProgress {
                        ProgressView(value: Double(progress.done),
                                     total: Double(max(progress.total, 1)))
                            .frame(width: 90)
                        Text("\(progress.done)/\(progress.total)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Button(extracted > 0 ? "Extract Remaining" : "Extract") {
                            Task { await model.extractEntities(inPublication: venue) }
                        }
                        .font(.caption)
                    }
                }
            }
            ForEach(extractionSections, id: \.category) { section in
                Section("\(section.category) — across \(extracted) papers") {
                    ForEach(section.threads.filter { $0.paperIDs.count >= 2 }.prefix(30)) { thread in
                        threadRow(thread)
                    }
                }
            }
            if !usesAI {
                Section {
                    HStack {
                        Text("Threads read from titles now; an AI pass names them better.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.analysisInProgress.contains(venue) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Analyse") {
                                Task { await model.analysePublication(venue) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            Section {
                ForEach(threads) { thread in
                    threadRow(thread)
                }
            } header: {
                Text(usesAI ? "AI topics across \(analysis.papers.count) papers"
                            : "Title terms across \(analysis.papers.count) papers")
            }
        }
        .overlay {
            if threads.isEmpty {
                ContentUnavailableView {
                    Label("No Threads Yet", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("No theme spans two papers here yet.")
                }
            }
        }
    }

    private func threadRow(_ thread: Thread) -> some View {
        DisclosureGroup {
            ForEach(thread.paperIDs, id: \.self) { paperID in
                if let paper = analysis.papers.first(where: { $0.id == paperID }) {
                    Button {
                        model.openEPUBRecord(withID: paperID)
                    } label: {
                        Text(paper.title).font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        } label: {
            HStack {
                Text(thread.name)
                Spacer()
                weaveDots(count: thread.paperIDs.count)
                Text("\(thread.paperIDs.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func weaveDots(count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<min(count, 12), id: \.self) { _ in
                Circle().fill(Color.accentColor.opacity(0.6))
                    .frame(width: 4, height: 4)
            }
        }
    }
}
