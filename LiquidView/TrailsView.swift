import SwiftUI

// MARK: - The trail document

/// A trail's shape — David Millard's three models of location-based
/// narrative (Canyons, Deltas and Plains, 2013), walked here through a
/// library instead of a landscape.
nonisolated enum TrailShape: String, CaseIterable, Sendable {
    /// One path: the stops open strictly in sequence.
    case canyon
    /// Branching paths: a stop opens when the stop it follows has been read.
    case delta
    /// An open field: every stop is open; walk in any order.
    case plain

    var displayName: String { rawValue.capitalized }

    /// The shape explained, as written into the trail document and shown
    /// in the view.
    var explanation: String {
        switch self {
        case .canyon: "one path; the stops open strictly in sequence"
        case .delta: "branching paths; a stop opens when the stop it follows has been read"
        case .plain: "an open field; every stop is open, walk in any order"
        }
    }
}

/// A trail as an Origami document: a sculptural reading path through the
/// community's documents, after the sculptural hypertext of Mark
/// Bernstein, David E. Millard, and Mark Weal — stops are not linked in
/// prose but declared, and a reader's app opens each stop only as the
/// stops it follows are read. The trail lives in the community folder
/// like anything else on the record; walking it is each reader's own,
/// local and private like muting and filing.
nonisolated enum TrailDocument {

    /// The `documentType` token; explained in the format specification.
    static let documentType = "trail"

    /// One stop as declared in the document: the document it visits and,
    /// for a delta, the stop it follows.
    struct Stop: Sendable {
        let docID: String
        var parentID: String? = nil
    }

    /// Builds the trail's document, ready for the Visual-Meta appendix
    /// and serialization. Titles travel with the addresses so the trail
    /// reads as prose in any text editor.
    static func build(id: String, name: String, author: String, created: Date,
                      shape: TrailShape, stops: [Stop],
                      titles: [String: String], in folder: URL) -> LiquidDoc {
        var paragraphs: [LiquidDoc.Paragraph] = []
        var links: [LiquidDoc.Link] = []
        var linked: Set<String> = []
        var counter = 0
        func add(_ text: String, heading: Int? = nil) {
            counter += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(counter)", heading: heading, text: text))
        }
        add("This document is a trail: a sculptural reading path through the community's documents, after the sculptural hypertext of Mark Bernstein, David E. Millard, and Mark Weal. A trail does not link its stops in prose — it declares them, and a reader's app opens each stop only as the stops it follows are read. Walking is each reader's own; nothing about it is written into the shared record.")
        add("Shape: \(shape.rawValue) — \(shape.explanation).")
        add("Stops", heading: 2)
        for (index, stop) in stops.enumerated() {
            let title = titles[stop.docID] ?? "Untitled"
            var line: String
            switch shape {
            case .canyon:
                line = "\(index + 1). “\(title)” [\(stop.docID)]"
            case .delta:
                if let parentID = stop.parentID {
                    let parentTitle = titles[parentID] ?? "Untitled"
                    line = "— “\(title)” [\(stop.docID)] after “\(parentTitle)” [\(parentID)]"
                } else {
                    line = "— “\(title)” [\(stop.docID)] from the start"
                }
            case .plain:
                line = "— “\(title)” [\(stop.docID)]"
            }
            add(line)
            if linked.insert(stop.docID).inserted {
                links.append(LiquidDoc.Link(to: stop.docID, fragment: nil, rel: "cites"))
            }
        }
        let slug = LiquidDoc.fileSlug(from: name)
        let ext = LiquidDoc.fileExtension
        let fileName = slug.isEmpty ? "\(id).\(ext)" : "\(slug)--\(id).\(ext)"
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: name,
                            author: author,
                            created: created,
                            body: paragraphs,
                            links: links,
                            wraps: nil,
                            fileURL: folder.appendingPathComponent(fileName))
        doc.documentType = documentType
        return doc
    }

    /// Reads a trail back from its document; nil when the document is not
    /// a trail. Tolerant of hand edits: shape from its "Shape:" line
    /// (plain when absent), stops from the addresses each paragraph after
    /// the Stops heading carries — the first address is the stop, and a
    /// second following the word "after" is the stop it follows. Canyon
    /// parents are implied by order.
    static func parse(_ doc: LiquidDoc) -> (shape: TrailShape, stops: [Stop])? {
        guard doc.documentType == documentType else { return nil }
        let appendixIDs = doc.visualMetaParagraphIDs
        var shape = TrailShape.plain
        var stops: [Stop] = []
        var inStops = false
        for paragraph in (doc.body ?? []) where !appendixIDs.contains(paragraph.id) {
            let text = paragraph.displayText
            if text.hasPrefix("Shape: ") {
                let token = text.dropFirst("Shape: ".count)
                    .prefix { $0.isLetter }
                if let parsed = TrailShape(rawValue: String(token).lowercased()) {
                    shape = parsed
                }
                continue
            }
            if paragraph.effectiveHeading != nil {
                inStops = text == "Stops"
                continue
            }
            guard inStops else { continue }
            let matches = LiquidAddress.matches(in: text)
            guard let first = matches.first else { continue }
            var parentID: String?
            if text.contains(" after "), matches.count > 1 {
                parentID = LiquidAddress.canonical(matches[1].id)
            }
            stops.append(Stop(docID: LiquidAddress.canonical(first.id), parentID: parentID))
        }
        guard !stops.isEmpty else { return nil }
        if shape == .canyon {
            for index in stops.indices {
                stops[index].parentID = index > 0 ? stops[index - 1].docID : nil
            }
        }
        return (shape, stops)
    }
}

// MARK: - Walking state

/// How far each reader has walked each trail — local and private, like
/// muting, filing, and read-state: who has walked what is never written
/// into the shared record.
nonisolated enum TrailProgress {
    static let key = "trailProgress"

    static func read(trailID: String) -> Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[trailID] ?? [])
    }

    static func save(trailID: String, read: Set<String>) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        if read.isEmpty {
            all[trailID] = nil
        } else {
            all[trailID] = read.sorted()
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - The view

/// Trails: sculptural reading paths through the library. In sculptural
/// hypertext nothing is linked and everything is potentially connected —
/// structure is carved away by constraints; here, by reading. A trail is
/// itself a document in the community folder (documentType "trail"),
/// written by anyone, walked by everyone, each at their own pace. The
/// built-in trail is the library itself: its discourse links become the
/// constraints, so a response opens only once what it responds to has
/// been read.
struct TrailsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTrailID = TrailsView.libraryTrailID
    @State private var readIDs: Set<String> = []
    @State private var isCreating = false

    static let libraryTrailID = "library"

    /// One stop, resolved and ready to walk: parents are the stops that
    /// must be read before this one opens.
    struct WalkStop: Identifiable {
        let id: String
        let title: String
        let author: String
        let parents: [String]
        /// False when the trail cites a document that has not arrived yet
        /// — forward citation. An absent stop cannot be walked, and never
        /// blocks the stops beyond it.
        let inLibrary: Bool
    }

    struct Trail: Identifiable {
        let id: String
        let name: String
        let author: String
        let shape: TrailShape
        let stops: [WalkStop]
        let isBuiltIn: Bool
    }

    // MARK: Assembling the trails

    /// Every trail on offer: the built-in walk of the whole library
    /// first, then every trail document in the community folder, oldest
    /// first.
    private var trails: [Trail] {
        var list = [libraryTrail()]
        let entries = model.index.byID.values
            .sorted { $0.doc.created < $1.doc.created }
        for entry in entries {
            guard let parsed = TrailDocument.parse(entry.doc) else { continue }
            list.append(Trail(id: entry.id,
                              name: entry.doc.title,
                              author: entry.doc.displayAuthor,
                              shape: parsed.shape,
                              stops: resolve(parsed.stops),
                              isBuiltIn: false))
        }
        return list
    }

    private var selectedTrail: Trail? {
        trails.first { $0.id == selectedTrailID } ?? trails.first
    }

    /// Declared stops become walkable ones: addresses resolve forward to
    /// their latest revisions, titles come from the index, and a stop the
    /// library does not hold yet is kept — visible, unwalkable, and never
    /// in the way.
    private func resolve(_ stops: [TrailDocument.Stop]) -> [WalkStop] {
        let byID = model.index.byID
        func resolved(_ id: String) -> String {
            model.index.latestRevision(of: LiquidAddress.canonical(id))
        }
        var seen: Set<String> = []
        var walkStops: [WalkStop] = []
        for stop in stops {
            let id = resolved(stop.docID)
            guard seen.insert(id).inserted else { continue }
            let entry = byID[id]
            walkStops.append(WalkStop(id: id,
                                      title: entry?.doc.title ?? stop.docID,
                                      author: entry?.doc.displayAuthor ?? "not yet in the library",
                                      parents: stop.parentID.map { [resolved($0)] } ?? [],
                                      inLibrary: entry != nil))
        }
        return walkStops
    }

    /// The library itself as a sculptural hypertext: every text document
    /// is a stop, and the discourse links are the constraints — a
    /// document that responds to, extends, supports, questions, disagrees
    /// with, or revises another opens only once that other has been read.
    /// Only links that point backward in time carve (a response is always
    /// younger than what it answers), so the walk can never deadlock.
    private func libraryTrail() -> Trail {
        let carvingRels: Set<String> = ["responds-to", "extends", "supports",
                                        "questions", "disagrees-with", "revises"]
        let byID = model.index.byID
        let entries = byID.values
            .filter { $0.doc.body != nil }
            .filter { $0.doc.documentType != BotDocument.documentType }
            .filter { $0.doc.documentType != TrailDocument.documentType }
            .sorted { $0.doc.created < $1.doc.created }
        let included = Set(entries.map(\.id))
        let stops = entries.map { entry in
            var parents: [String] = []
            for link in entry.doc.links {
                guard let rel = link.rel, carvingRels.contains(rel) else { continue }
                let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                guard target != entry.id, included.contains(target),
                      let targetEntry = byID[target],
                      targetEntry.doc.created < entry.doc.created,
                      !parents.contains(target) else { continue }
                parents.append(target)
            }
            return WalkStop(id: entry.id,
                            title: entry.doc.title,
                            author: entry.doc.displayAuthor,
                            parents: parents,
                            inLibrary: true)
        }
        return Trail(id: Self.libraryTrailID,
                     name: "The Whole Library",
                     author: "carved by its own links",
                     shape: .delta,
                     stops: stops,
                     isBuiltIn: true)
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            trailShelf
            Divider()
            if let trail = selectedTrail, !trail.stops.isEmpty {
                walk(trail)
            } else {
                ContentUnavailableView(
                    "No Stops",
                    systemImage: "signpost.right",
                    description: Text("Add documents to the community folder, or lay a new trail — a trail is itself a document anyone can write."))
            }
        }
        .onAppear { readIDs = TrailProgress.read(trailID: selectedTrailID) }
        .onChange(of: selectedTrailID) {
            readIDs = TrailProgress.read(trailID: selectedTrailID)
        }
        .sheet(isPresented: $isCreating) {
            NewTrailSheet { id in
                selectedTrailID = id
            }
        }
    }

    /// The trails on offer, and the making of new ones.
    private var trailShelf: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(trails) { trail in
                        trailChip(trail)
                    }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            Button {
                isCreating = true
            } label: {
                Label("New Trail…", systemImage: "plus")
            }
            .help("Lay a trail of your own — a document in the community folder that anyone can walk")
        }
        .padding(10)
    }

    private func trailChip(_ trail: Trail) -> some View {
        let isSelected = trail.id == selectedTrailID
        return Button {
            selectedTrailID = trail.id
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(trail.name)
                    .fontWeight(isSelected ? .bold : .regular)
                    .lineLimit(1)
                Text("\(trail.shape.displayName) · \(trail.author)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                   : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .help("\(trail.shape.displayName): \(trail.shape.explanation)")
        .contextMenu {
            Button("Start Over") {
                readIDs = []
                TrailProgress.save(trailID: trail.id, read: [])
            }
            if !trail.isBuiltIn {
                Divider()
                Button("Delete Trail", role: .destructive) {
                    deleteTrail(trail)
                }
            }
        }
    }

    private func deleteTrail(_ trail: Trail) {
        guard let entry = model.index.byID[trail.id] else { return }
        try? FileManager.default.trashItem(at: entry.doc.fileURL, resultingItemURL: nil)
        TrailProgress.save(trailID: trail.id, read: [])
        if selectedTrailID == trail.id { selectedTrailID = Self.libraryTrailID }
    }

    // MARK: The walk

    private let columnSpacing: CGFloat = 230
    private let rowSpacing: CGFloat = 92
    private let cardWidth: CGFloat = 170

    private func walk(_ trail: Trail) -> some View {
        let positions = layout(trail)
        let maxX = positions.values.map(\.x).max() ?? 0
        let maxY = positions.values.map(\.y).max() ?? 0
        return ScrollView([.horizontal, .vertical]) {
            ZStack {
                edgeThreads(trail, positions: positions)
                ForEach(trail.stops) { stop in
                    card(for: stop, in: trail)
                        .position(positions[stop.id] ?? .zero)
                }
            }
            .frame(width: maxX + cardWidth / 2 + 40, height: maxY + 80)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { legend(trail) }
    }

    /// Where each stop stands: a plain is a field (a grid, any order);
    /// canyons and deltas march left to right by depth — how much must be
    /// read before a stop can open — with each column stacked in trail
    /// order.
    private func layout(_ trail: Trail) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        let origin = CGPoint(x: cardWidth / 2 + 40, y: 70)
        if trail.shape == .plain {
            let columns = max(1, Int(Double(trail.stops.count).squareRoot().rounded(.up)))
            for (index, stop) in trail.stops.enumerated() {
                positions[stop.id] = CGPoint(
                    x: origin.x + Double(index % columns) * columnSpacing,
                    y: origin.y + Double(index / columns) * rowSpacing)
            }
            return positions
        }
        let depths = depthByStop(trail)
        var rowsUsed: [Int: Int] = [:]
        for stop in trail.stops {
            let depth = depths[stop.id] ?? 0
            let row = rowsUsed[depth, default: 0]
            rowsUsed[depth] = row + 1
            positions[stop.id] = CGPoint(x: origin.x + Double(depth) * columnSpacing,
                                         y: origin.y + Double(row) * rowSpacing)
        }
        return positions
    }

    /// A stop's depth: the longest chain of reading that stands before
    /// it. Cycles (possible only in a hand-edited trail) break as roots.
    private func depthByStop(_ trail: Trail) -> [String: Int] {
        let byID = Dictionary(trail.stops.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var memo: [String: Int] = [:]
        var visiting: Set<String> = []
        func depth(_ id: String) -> Int {
            if let done = memo[id] { return done }
            guard let stop = byID[id], visiting.insert(id).inserted else { return 0 }
            defer { visiting.remove(id) }
            let value = stop.parents
                .filter { byID[$0] != nil }
                .map { depth($0) + 1 }
                .max() ?? 0
            memo[id] = value
            return value
        }
        for stop in trail.stops { _ = depth(stop.id) }
        return memo
    }

    /// A stop is open when every stop it follows has been read. A parent
    /// the library does not hold cannot be walked, so it never bars the
    /// way.
    private func isOpen(_ stop: WalkStop, in trail: Trail) -> Bool {
        let byID = Dictionary(trail.stops.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        return stop.parents.allSatisfy { parent in
            readIDs.contains(parent) || byID[parent]?.inLibrary != true
        }
    }

    @ViewBuilder
    private func card(for stop: WalkStop, in trail: Trail) -> some View {
        let isRead = readIDs.contains(stop.id)
        let open = isOpen(stop, in: trail)
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                if isRead {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green.mix(with: .black, by: 0.25))
                } else if !open || !stop.inLibrary {
                    Image(systemName: stop.inLibrary ? "lock.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(stop.title)
                    .font(.system(size: 12, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text(stop.author)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: cardWidth)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isRead ? Color.green.mix(with: .black, by: 0.25)
                        : open && stop.inLibrary ? Color.accentColor
                        : Color.secondary.opacity(0.25),
                        lineWidth: open && !isRead && stop.inLibrary ? 2 : 1)
        )
        .opacity(open || isRead ? 1 : 0.45)
        .onTapGesture(count: 2) {
            guard open, stop.inLibrary, let entry = model.index.byID[stop.id] else { return }
            markRead(stop, in: trail)
            model.openInLibrary(entry.doc)
        }
        .onTapGesture {
            guard open, stop.inLibrary, !isRead else { return }
            markRead(stop, in: trail)
        }
        .contextMenu {
            if isRead {
                Button("Mark as Unread") {
                    withAnimation(.snappy) { _ = readIDs.remove(stop.id) }
                    TrailProgress.save(trailID: trail.id, read: readIDs)
                }
            }
        }
        .help(helpText(for: stop, in: trail, open: open, isRead: isRead))
    }

    private func markRead(_ stop: WalkStop, in trail: Trail) {
        withAnimation(.snappy) { _ = readIDs.insert(stop.id) }
        TrailProgress.save(trailID: trail.id, read: readIDs)
    }

    private func helpText(for stop: WalkStop, in trail: Trail, open: Bool, isRead: Bool) -> String {
        if !stop.inLibrary {
            return "Cited before its arrival — this stop opens when the document reaches the library"
        }
        if isRead { return "Walked · double-click to read again" }
        if open { return "Open · click to walk it, double-click to read" }
        let byID = Dictionary(trail.stops.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        let waiting = stop.parents
            .filter { byID[$0]?.inLibrary == true && !readIDs.contains($0) }
            .compactMap { byID[$0]?.title }
        return "Opens after: \(waiting.joined(separator: ", "))"
    }

    /// The constraints made visible: a thread from each stop to the stops
    /// it opens. Threads a reader has walked through are drawn a little
    /// firmer.
    private func edgeThreads(_ trail: Trail, positions: [String: CGPoint]) -> some View {
        Canvas { context, _ in
            for stop in trail.stops {
                guard let to = positions[stop.id] else { continue }
                for parent in stop.parents {
                    guard let from = positions[parent] else { continue }
                    var path = Path()
                    path.move(to: from)
                    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                    path.addQuadCurve(to: to, control: CGPoint(x: mid.x, y: from.y))
                    let walked = readIDs.contains(parent)
                    context.stroke(path,
                                   with: .color(.secondary.opacity(walked ? 0.5 : 0.2)),
                                   lineWidth: walked ? 1.5 : 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func legend(_ trail: Trail) -> some View {
        let read = trail.stops.filter { readIDs.contains($0.id) }.count
        let total = trail.stops.filter(\.inLibrary).count
        return HStack(spacing: 12) {
            Text("\(trail.shape.displayName): \(trail.shape.explanation)")
            Text("\(read) of \(total) walked")
                .monospacedDigit()
            Text("click an open stop to walk it · double-click to read")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 10)
    }
}

// MARK: - Laying a new trail

/// Laying a trail: name it, choose its shape, and gather its stops from
/// the library. The trail is written into the community folder as an
/// ordinary document — anyone who syncs the folder can walk it.
private struct NewTrailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with the new trail's address once it is written.
    let onCreate: (String) -> Void

    @State private var name = ""
    @State private var shape: TrailShape = .canyon
    @State private var search = ""
    @State private var stops: [ChosenStop] = []
    @State private var notice: String?

    private struct ChosenStop: Identifiable {
        let id = UUID()
        let docID: String
        let title: String
        /// For a delta: the stop this one follows, nil meaning the start.
        var parentDocID: String? = nil
    }

    private var libraryEntries: [IndexEntry] {
        let chosen = Set(stops.map(\.docID))
        return model.filteredEntries
            .filter { $0.doc.body != nil }
            .filter { $0.doc.documentType != BotDocument.documentType }
            .filter { $0.doc.documentType != TrailDocument.documentType }
            .filter { !chosen.contains($0.id) }
            .filter {
                search.isEmpty
                    || $0.doc.title.localizedCaseInsensitiveContains(search)
                    || $0.doc.displayAuthor.localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lay a Trail")
                .font(.title3)
            TextField("The trail's name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Shape", selection: $shape) {
                ForEach(TrailShape.allCases, id: \.self) { shape in
                    Text(shape.displayName).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("\(shape.displayName): \(shape.explanation).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 14) {
                libraryColumn
                stopsColumn
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("The trail becomes a document in the community folder; anyone who syncs it can walk it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Lay the Trail") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || stops.count < 2)
            }
        }
        .padding(16)
        .frame(width: 720, height: 520)
    }

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search the library", text: $search)
                .textFieldStyle(.roundedBorder)
            List(libraryEntries) { entry in
                Button {
                    stops.append(ChosenStop(docID: entry.id, title: entry.doc.title,
                                            parentDocID: stops.last?.docID))
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.doc.title)
                                .lineLimit(1)
                            Text("\(entry.doc.displayAuthor) · \(entry.doc.listedDateText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    private var stopsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stops.isEmpty ? "Stops — click documents to add them" : "Stops, in trail order")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    HStack(spacing: 6) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stop.title)
                                .lineLimit(1)
                            if shape == .delta {
                                afterPicker(for: index)
                            }
                        }
                        Spacer()
                        Button {
                            guard index > 0 else { return }
                            stops.swapAt(index, index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                        Button {
                            guard index < stops.count - 1 else { return }
                            stops.swapAt(index, index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(index == stops.count - 1)
                        Button {
                            let removed = stops.remove(at: index)
                            // Stops that followed the removed one return
                            // to the start rather than pointing nowhere.
                            for other in stops.indices where stops[other].parentDocID == removed.docID {
                                stops[other].parentDocID = nil
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }

    /// The delta's branching, chosen per stop: which earlier stop this
    /// one follows, or the start.
    private func afterPicker(for index: Int) -> some View {
        Picker("After", selection: $stops[index].parentDocID) {
            Text("the start").tag(String?.none)
            ForEach(stops.prefix(index)) { earlier in
                Text(earlier.title).tag(String?.some(earlier.docID))
            }
        }
        .pickerStyle(.menu)
        .controlSize(.mini)
        .fixedSize()
    }

    private func create() {
        guard let folder = model.index.folderURL else {
            notice = "Choose a community folder first — the trail lives there."
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let created = Date.now
        let author = model.authorName
        let taken = Set(model.index.byID.keys)
        let id = LiquidAddress.makeID(author: author, created: created,
                                      isTaken: { taken.contains($0) })
        let ordered = Dictionary(uniqueKeysWithValues: stops.enumerated().map { ($1.docID, $0) })
        let documentStops = stops.enumerated().map { index, stop in
            // A delta stop may only follow an earlier one; anything else
            // walks from the start.
            let parent = stop.parentDocID.flatMap { ordered[$0].map { $0 < index ? stop.parentDocID : nil } ?? nil }
            return TrailDocument.Stop(docID: stop.docID,
                                      parentID: shape == .delta ? parent : nil)
        }
        let titles = Dictionary(uniqueKeysWithValues: stops.map { ($0.docID, $0.title) })
        let doc = VisualMeta.appendingAppendix(
            to: TrailDocument.build(id: id, name: trimmed, author: author,
                                    created: created, shape: shape,
                                    stops: documentStops, titles: titles, in: folder))
        do {
            try doc.jsonData().write(to: doc.fileURL, options: .atomic)
            model.showNote("“\(trimmed)” is laid — anyone who syncs the folder can walk it.")
            onCreate(id)
            dismiss()
        } catch {
            notice = "Could not write the trail: \(error.localizedDescription)"
        }
    }
}

extension TrailsView {
    /// Trails as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "trails",
        name: "Trails",
        systemImage: "signpost.right",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(TrailsView()) },
        hidesDocumentList: true
    )
}
