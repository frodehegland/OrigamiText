import SwiftUI

/// The Geometry of Thought, demonstrated: the same library rendered
/// through five representational geometries at once — a line, a
/// hierarchy, sets, a graph, and a canvas — after David Millard's essay
/// of that name (The Stranger's Notebook, 2026): knowledge interfaces
/// are not neutral, each geometry affords different thoughts. Click a
/// document anywhere and every pane lights it up along with the
/// neighbours *that geometry* gives it: the line offers before and
/// after, the hierarchy offers siblings, sets offer fellow members, the
/// graph offers what it actually touches, the canvas offers whatever
/// was placed nearby. Same document, five different neighbourhoods —
/// the geometry decides what can be seen, and so what can be thought.
struct GeometriesView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?
    /// Where each document sits on the canvas pane — seeded from the
    /// document's address so the field is stable, then the reader's to
    /// rearrange: proximity without commitment.
    @State private var canvasPositions: [String: CGPoint] = [:]
    @State private var dragStart: [String: CGPoint] = [:]

    /// What all five geometries render: every text document, bots and
    /// trails excluded, oldest first — the one library, five ways.
    private var entries: [IndexEntry] {
        model.filteredEntries
            .filter { $0.doc.body != nil }
            .filter { $0.doc.documentType != BotDocument.documentType }
            .filter { $0.doc.documentType != TrailDocument.documentType }
            .sorted { $0.doc.listedDate < $1.doc.listedDate }
    }

    private var selectedEntry: IndexEntry? {
        entries.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Documents",
                    systemImage: "square.on.circle",
                    description: Text("Add documents to the community folder and the five geometries will render them."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        pane("The Line",
                             caption: "Sequence — a document has a before and an after, nothing else.",
                             related: lineNeighbours()) { linePane }
                        pane("The Hierarchy",
                             caption: "Belonging — exactly one parent each; the neighbours are the siblings.",
                             related: hierarchyNeighbours()) { hierarchyPane }
                        pane("The Sets",
                             caption: "Overlap — a document may belong to several sets at once.",
                             related: setNeighbours()) { setsPane }
                        pane("The Graph",
                             caption: "Relation — the neighbours are what a document actually touches.",
                             related: graphNeighbours()) { graphPane }
                        pane("The Canvas",
                             caption: "Proximity without commitment — near because someone put it there.",
                             related: canvasNeighbours()) { canvasPane }
                        explainerPane
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("The same library, five geometries — each affords different thoughts.")
                    .font(.callout)
                Text("After David Millard's “The Geometry of Thought”. Click a document anywhere: every pane shows the neighbours its geometry gives it. Double-click to read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let entry = selectedEntry {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(entry.doc.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.doc.displayAuthor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .padding(10)
    }

    // MARK: - The panes

    /// One geometry's pane: header, caption, and its rendering. The
    /// related set is computed by the pane's own geometry — the point of
    /// the whole view.
    private func pane<Content: View>(_ title: String, caption: String,
                                     related: Set<String>,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppFonts.body(15, weight: .bold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            content()
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 200)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .environment(\.geometryRelatedIDs, related)
        }
        .padding(10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The essay's argument, standing where a sixth pane would.
    private var explainerPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why five?")
                .font(AppFonts.body(15, weight: .bold))
            Text("A hierarchy can say “this belongs here” but not “these two touch”. A line can say “this came after” and nothing more. The graph knows relations but not nearness; the canvas knows nearness but commits to nothing. None of them is the library — each is one geometry of it, and whichever one a tool offers becomes the shape of its readers' thinking. A chat window, Millard warns, is the poorest geometry of all: a line that forgets.")
                .font(.callout)
            Spacer(minLength: 0)
            Text("Millard, D. “The Geometry of Thought”, The Stranger's Notebook, May 2026 — building on Engelbart's H-LAM/T framework.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 262, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: The line

    /// Creation order and nothing else: the chat geometry, made honest.
    private var linePane: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: 0) {
                        if index > 0 {
                            Rectangle()
                                .fill(.secondary.opacity(0.3))
                                .frame(width: 22, height: 1)
                        }
                        VStack(spacing: 3) {
                            dot(for: entry)
                            Text(entry.doc.title)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 56)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 200)
        }
    }

    private func lineNeighbours() -> Set<String> {
        guard let index = entries.firstIndex(where: { $0.id == selectedID }) else { return [] }
        var related: Set<String> = []
        if index > 0 { related.insert(entries[index - 1].id) }
        if index < entries.count - 1 { related.insert(entries[index + 1].id) }
        return related
    }

    // MARK: The hierarchy

    /// One parent each — here, the author. The folder geometry.
    private var hierarchyPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(authorGroups, id: \.author) { group in
                    Text(group.author)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.entries) { entry in
                        HStack(spacing: 5) {
                            dot(for: entry)
                            Text(entry.doc.title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .padding(.leading, 14)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var authorGroups: [(author: String, entries: [IndexEntry])] {
        Dictionary(grouping: entries) { $0.doc.displayAuthor }
            .map { (author: $0.key, entries: $0.value) }
            .sorted { $0.author < $1.author }
    }

    private func hierarchyNeighbours() -> Set<String> {
        guard let entry = selectedEntry else { return [] }
        return Set(entries
            .filter { $0.doc.displayAuthor == entry.doc.displayAuthor && $0.id != entry.id }
            .map(\.id))
    }

    // MARK: The sets

    /// Overlapping membership: a document sits in the set of its kind,
    /// and also — when addressed to you — in the attention set. The tag
    /// geometry: one dot may appear in several places.
    private var documentSets: [(name: String, entries: [IndexEntry])] {
        var sets = Dictionary(grouping: entries) { $0.doc.documentType ?? "letter" }
            .map { (name: $0.key, entries: $0.value) }
            .sorted { $0.name < $1.name }
        let attentionIDs = Set(model.attentionEntries.map(\.id))
        let attention = entries.filter { attentionIDs.contains($0.id) }
        if !attention.isEmpty {
            sets.append((name: "for your attention", entries: attention))
        }
        return sets
    }

    private var setsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(documentSets, id: \.name) { set in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(set.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        FlowDots(entries: set.entries) { entry in
                            dot(for: entry)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(8)
        }
    }

    private func setNeighbours() -> Set<String> {
        guard let selectedID else { return [] }
        var related: Set<String> = []
        for set in documentSets where set.entries.contains(where: { $0.id == selectedID }) {
            related.formUnion(set.entries.map(\.id))
        }
        related.remove(selectedID)
        return related
    }

    // MARK: The graph

    /// Nodes on a circle, links as chords: relation made explicit — the
    /// wiki geometry, and this library's native one.
    private var graphPane: some View {
        GeometryReader { geometry in
            let positions = circlePositions(in: geometry.size)
            ZStack {
                Canvas { context, _ in
                    for entry in entries {
                        guard let from = positions[entry.id] else { continue }
                        for link in entry.doc.links {
                            let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                            guard target != entry.id, let to = positions[target] else { continue }
                            let touched = entry.id == selectedID || target == selectedID
                            var path = Path()
                            path.move(to: from)
                            path.addLine(to: to)
                            context.stroke(path,
                                           with: .color(touched ? .accentColor : .secondary.opacity(0.2)),
                                           lineWidth: touched ? 1.5 : 1)
                        }
                    }
                }
                ForEach(entries) { entry in
                    dot(for: entry)
                        .position(positions[entry.id] ?? .zero)
                }
            }
        }
        .padding(6)
    }

    private func circlePositions(in size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 16
        var positions: [String: CGPoint] = [:]
        for (index, entry) in entries.enumerated() {
            let angle = Double(index) / Double(max(entries.count, 1)) * 2 * .pi - .pi / 2
            positions[entry.id] = CGPoint(x: center.x + cos(angle) * radius,
                                          y: center.y + sin(angle) * radius)
        }
        return positions
    }

    private func graphNeighbours() -> Set<String> {
        guard let selectedID else { return [] }
        var related: Set<String> = []
        let included = Set(entries.map(\.id))
        for entry in entries {
            for link in entry.doc.links {
                let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                guard included.contains(target) else { continue }
                if entry.id == selectedID, target != selectedID { related.insert(target) }
                if target == selectedID, entry.id != selectedID { related.insert(entry.id) }
            }
        }
        return related
    }

    // MARK: The canvas

    /// Spatial hypertext's geometry: things are near because someone put
    /// them there. Seeded from each address, then the reader's to drag.
    private var canvasPane: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(entries) { entry in
                    dot(for: entry)
                        .position(canvasPosition(entry.id, in: geometry.size))
                        .gesture(canvasDrag(for: entry.id, in: geometry.size))
                }
            }
        }
        .padding(6)
    }

    private func canvasPosition(_ id: String, in size: CGSize) -> CGPoint {
        if let placed = canvasPositions[id] { return placed }
        // A stable scatter: the address hashes to the same spot every
        // launch, so the field means something until it is rearranged.
        let hash = stableHash(id)
        let x = 20 + Double(hash % 1000) / 1000 * max(size.width - 40, 1)
        let y = 20 + Double((hash / 1000) % 1000) / 1000 * max(size.height - 40, 1)
        return CGPoint(x: x, y: y)
    }

    private func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }

    private func canvasDrag(for id: String, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart[id] ?? canvasPosition(id, in: size)
                if dragStart[id] == nil { dragStart[id] = start }
                canvasPositions[id] = CGPoint(x: start.x + value.translation.width,
                                              y: start.y + value.translation.height)
            }
            .onEnded { _ in dragStart[id] = nil }
    }

    private func canvasNeighbours() -> Set<String> {
        guard let selectedID else { return [] }
        // Whatever sits nearest in the field right now — the size used
        // for seeding only matters for unplaced dots, and only relative
        // distance is asked of it.
        let size = CGSize(width: 400, height: 200)
        let here = canvasPosition(selectedID, in: size)
        let nearest = entries
            .filter { $0.id != selectedID }
            .map { (id: $0.id, distance: hypot(canvasPosition($0.id, in: size).x - here.x,
                                               canvasPosition($0.id, in: size).y - here.y)) }
            .sorted { $0.distance < $1.distance }
            .prefix(2)
        return Set(nearest.map(\.id))
    }

    // MARK: The shared dot

    /// One document, wherever it appears: the same dot in every
    /// geometry, so the eye can follow it across the panes. Accent when
    /// selected, ringed when it is a neighbour in *this* pane's geometry.
    private func dot(for entry: IndexEntry) -> some View {
        GeometryDot(entry: entry,
                    isSelected: entry.id == selectedID,
                    onSelect: { selectedID = entry.id },
                    onOpen: { model.openInLibrary(entry.doc) })
    }
}

/// The related set for the pane a dot sits in, carried down the
/// environment so the one dot view serves all five geometries.
private struct GeometryRelatedIDsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

private extension EnvironmentValues {
    var geometryRelatedIDs: Set<String> {
        get { self[GeometryRelatedIDsKey.self] }
        set { self[GeometryRelatedIDsKey.self] = newValue }
    }
}

private struct GeometryDot: View {
    @Environment(\.geometryRelatedIDs) private var relatedIDs
    let entry: IndexEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        let isRelated = relatedIDs.contains(entry.id)
        Circle()
            .fill(isSelected ? Color.accentColor
                  : isRelated ? Color.orange
                  : Color.secondary.opacity(0.55))
            .frame(width: isSelected ? 13 : 10, height: isSelected ? 13 : 10)
            .overlay(
                Circle()
                    .strokeBorder(isRelated ? Color.orange : .clear, lineWidth: 2)
                    .frame(width: 17, height: 17)
            )
            .frame(width: 18, height: 18)
            .contentShape(Circle())
            .onTapGesture(count: 2, perform: onOpen)
            .onTapGesture(perform: onSelect)
            .help("\(entry.doc.title) — \(entry.doc.displayAuthor)")
            .animation(.snappy, value: isSelected)
            .animation(.snappy, value: isRelated)
    }
}

/// Dots flowing left to right, wrapping as they run out of room — sets
/// need their members visible together, however many there are.
private struct FlowDots<Dot: View>: View {
    let entries: [IndexEntry]
    @ViewBuilder let dot: (IndexEntry) -> Dot

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 20), spacing: 2)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
            ForEach(entries) { entry in
                dot(entry)
            }
        }
    }
}

extension GeometriesView {
    /// The geometry demonstration as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "geometries",
        name: "Geometries",
        systemImage: "square.on.circle",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(GeometriesView()) },
        hidesDocumentList: true
    )
}
