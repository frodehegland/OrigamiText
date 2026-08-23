import SwiftUI

/// Glossary Space: the reader's glossary as a map. Every term is a
/// node, sized by how often the community speaks it, and the threads
/// are found, not drawn: a firm thread where two terms share a
/// paragraph, a faint one where they merely share a document, and a
/// dashed accent thread where the reader's own gloss for one term
/// speaks another — the reader's hand-made links, in the spirit of
/// Blustein's reader-controlled linking and the spatial hypertext
/// tradition. Terms are the reader's to drag; Arrange lets the
/// connections lay the space out afresh.
struct GlossarySpaceView: View {
    @Environment(AppModel.self) private var model
    @State private var nodes: [TermNode] = []
    @State private var edges: [TermEdge] = []
    @State private var positions: [String: CGPoint] = [:]
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var selectedID: String?
    /// The node whose gloss is on display; set by hover, cleared by the
    /// background, exactly as the bots' space behaves.
    @State private var hoveredID: String?

    /// One term standing in the space.
    struct TermNode: Identifiable {
        let id: String
        let term: String
        let gloss: String
        /// Paragraphs in the library that speak the term — the node's size.
        let count: Int
    }

    /// One connection between two terms, with everything that makes it.
    struct TermEdge: Identifiable {
        let a: String
        let b: String
        /// Paragraphs both terms share — the strong tie.
        var paragraphs: Int = 0
        /// Documents both terms share — the loose tie.
        var documents: Int = 0
        /// True when one term's gloss speaks the other — the reader's own link.
        var glossed = false
        var id: String { "\(a)→\(b)" }

        /// The edge's visual weight, paragraph ties counting most and the
        /// reader's own link counting for plenty.
        var weight: Double {
            Double(paragraphs) * 3 + Double(documents) + (glossed ? 4 : 0)
        }
    }

    var body: some View {
        Group {
            if nodes.isEmpty {
                ContentUnavailableView(
                    "No Terms Yet",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Add terms to your Glossary and this space maps them: sized by how often the community speaks them, connected where the discourse — or your own glosses — join them."))
            } else {
                space
            }
        }
        .onAppear { rebuild() }
        .onChange(of: model.index.byID.count) { rebuild() }
    }

    private var space: some View {
        GeometryReader { geometry in
            ZStack {
                threads
                ForEach(nodes) { node in
                    chip(for: node)
                        .position(positions[node.id]
                                  ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
                        .gesture(drag(for: node.id))
                }
                if let node = hoveredNode {
                    glossPanel(node, in: geometry.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                hoveredID = nil
                selectedID = nil
            }
            .onAppear { seedIfNeeded(in: geometry.size) }
            .onChange(of: nodes.map(\.id)) { seedIfNeeded(in: geometry.size) }
            .overlay(alignment: .bottom) { legend(in: geometry.size) }
        }
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(.background)
        #endif
    }

    private var hoveredNode: TermNode? {
        nodes.first { $0.id == hoveredID }
    }

    // MARK: The threads

    private var threads: some View {
        Canvas { context, _ in
            for edge in edges {
                guard let from = positions[edge.a], let to = positions[edge.b] else { continue }
                let touched = edge.a == selectedID || edge.b == selectedID
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                if edge.paragraphs > 0 || edge.documents > 0 {
                    let width = min(1 + Double(edge.paragraphs) * 0.8, 4)
                    let opacity = edge.paragraphs > 0 ? 0.45 : 0.18
                    context.stroke(path,
                                   with: .color(touched ? .accentColor : .secondary.opacity(opacity)),
                                   lineWidth: touched ? max(width, 1.5) : width)
                }
                if edge.glossed {
                    // The reader's own link rides the same line, dashed,
                    // in accent — visible even where the discourse is silent.
                    context.stroke(path,
                                   with: .color(.accentColor.opacity(touched ? 0.9 : 0.5)),
                                   style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: The chips

    private func chip(for node: TermNode) -> some View {
        let isSelected = node.id == selectedID
        // Landmarks: the more the community speaks a term, the larger it
        // stands — gently, so no term shouts the others down.
        let fontSize = 12 + min(Double(node.count), 24) / 3
        return HStack(spacing: 5) {
            Text(node.term)
                .font(.system(size: fontSize, weight: .medium, design: .serif))
            if node.count > 0 {
                Text("\(node.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thickMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(isSelected ? Color.accentColor
                              : isNeighborOfSelection(node.id) ? Color.orange
                              : Color.secondary.opacity(0.3),
                              lineWidth: isSelected || isNeighborOfSelection(node.id) ? 2 : 1)
        )
        .onHover { inside in
            if inside { hoveredID = node.id }
        }
        .onTapGesture(count: 2) {
            // The term's own page: the Glossary view holds the gloss and
            // every passage that speaks it.
            model.sidebarSelection = .view("glossary")
        }
        .onTapGesture {
            selectedID = selectedID == node.id ? nil : node.id
        }
        .help(node.gloss.isEmpty
              ? "\(node.term) — no gloss yet · spoken in \(node.count) paragraph\(node.count == 1 ? "" : "s")"
              : "\(node.term) — \(node.gloss)")
    }

    private func isNeighborOfSelection(_ id: String) -> Bool {
        guard let selectedID, id != selectedID else { return false }
        return edges.contains {
            ($0.a == selectedID && $0.b == id) || ($0.b == selectedID && $0.a == id)
        }
    }

    /// The hover panel: the gloss in the reader's own words, and what
    /// ties this term to its neighbours.
    private func glossPanel(_ node: TermNode, in size: CGSize) -> some View {
        let anchor = positions[node.id] ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let ties = edges
            .filter { $0.a == node.id || $0.b == node.id }
            .sorted { $0.weight > $1.weight }
            .prefix(4)
        return VStack(alignment: .leading, spacing: 6) {
            Text(node.term)
                .font(.headline)
            Text(node.gloss.isEmpty ? "No gloss yet — write one in the Glossary view." : node.gloss)
                .font(.body)
                .foregroundStyle(node.gloss.isEmpty ? .secondary : .primary)
            if !ties.isEmpty {
                Divider()
                ForEach(Array(ties)) { edge in
                    let otherID = edge.a == node.id ? edge.b : edge.a
                    if let other = nodes.first(where: { $0.id == otherID }) {
                        Text(tieDescription(edge, other: other.term))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        // The shadow belongs to the panel, not its text — shadowing the
        // whole view softens every glyph.
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(radius: 4)
        }
        .position(x: min(max(anchor.x, 200), size.width - 200),
                  y: max(anchor.y - 90, 85))
    }

    private func tieDescription(_ edge: TermEdge, other: String) -> String {
        var parts: [String] = []
        if edge.paragraphs > 0 {
            parts.append("shares \(edge.paragraphs) paragraph\(edge.paragraphs == 1 ? "" : "s")")
        } else if edge.documents > 0 {
            parts.append("shares \(edge.documents) document\(edge.documents == 1 ? "" : "s")")
        }
        if edge.glossed {
            parts.append("your glosses join them")
        }
        return "\(other) — \(parts.joined(separator: " · "))"
    }

    private func legend(in size: CGSize) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 14, height: 2)
                Text("spoken together")
            }
            HStack(spacing: 4) {
                Line(dash: true)
                    .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                    .frame(width: 14, height: 2)
                Text("joined by your gloss")
            }
            Text("hover for the gloss · click to trace · drag to arrange")
                .foregroundStyle(.tertiary)
            Button("Arrange") {
                withAnimation(.snappy) { arrange(in: size) }
            }
            .controlSize(.small)
            .help("Let the connections lay the space out afresh")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 10)
    }

    private struct Line: Shape {
        var dash: Bool
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }

    // MARK: Movement

    private func drag(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart[id] ?? positions[id] ?? .zero
                if dragStart[id] == nil { dragStart[id] = start }
                positions[id] = CGPoint(x: start.x + value.translation.width,
                                        y: start.y + value.translation.height)
            }
            .onEnded { _ in dragStart[id] = nil }
    }

    // MARK: Building the space

    /// Reads the glossary and the library, and finds every tie: which
    /// paragraphs speak which terms, which documents hold them together,
    /// and which glosses speak other terms. Nothing is generated — the
    /// space renders what is already there.
    private func rebuild() {
        let terms = PersonalGlossary.load()
        let matchers = terms.compactMap { term in
            GlossaryView.matcher(for: term.term).map { (term: term, regex: $0) }
        }
        var counts: [String: Int] = [:]
        var pairKeys: [String: TermEdge] = [:]
        func edge(_ a: String, _ b: String, update: (inout TermEdge) -> Void) {
            let (first, second) = a < b ? (a, b) : (b, a)
            var existing = pairKeys["\(first)→\(second)"] ?? TermEdge(a: first, b: second)
            update(&existing)
            pairKeys["\(first)→\(second)"] = existing
        }
        let entries = model.filteredEntries
            .filter { $0.doc.body != nil }
            .filter { $0.doc.documentType != BotDocument.documentType }
            .filter { $0.doc.documentType != TrailDocument.documentType }
            .filter { $0.doc.documentType != PersonalGlossary.documentType }
        for entry in entries {
            let appendixIDs = entry.doc.visualMetaParagraphIDs
            var inDocument: Set<String> = []
            for paragraph in (entry.doc.body ?? []) where !appendixIDs.contains(paragraph.id) {
                let text = paragraph.displayText
                let range = NSRange(text.startIndex..., in: text)
                let spoken = matchers.filter { $0.regex.firstMatch(in: text, range: range) != nil }
                    .map(\.term.id)
                for id in spoken { counts[id, default: 0] += 1 }
                inDocument.formUnion(spoken)
                for i in spoken.indices {
                    for j in spoken.indices where j > i {
                        edge(spoken[i], spoken[j]) { $0.paragraphs += 1 }
                    }
                }
            }
            let together = Array(inDocument)
            for i in together.indices {
                for j in together.indices where j > i {
                    edge(together[i], together[j]) { $0.documents += 1 }
                }
            }
        }
        // The reader's own ties: a gloss that speaks another term.
        for a in terms {
            for b in matchers where b.term.id != a.id {
                let gloss = a.gloss
                let range = NSRange(gloss.startIndex..., in: gloss)
                if b.regex.firstMatch(in: gloss, range: range) != nil {
                    edge(a.id, b.term.id) { $0.glossed = true }
                }
            }
        }
        nodes = terms.map { TermNode(id: $0.id, term: $0.term, gloss: $0.gloss,
                                     count: counts[$0.id] ?? 0) }
        edges = pairKeys.values.filter { $0.weight > 0 }.sorted { $0.id < $1.id }
    }

    /// First arrangement only: new spaces lay themselves out by their
    /// connections; after that the space is the reader's.
    private func seedIfNeeded(in size: CGSize) {
        guard nodes.contains(where: { positions[$0.id] == nil }) else { return }
        arrange(in: size)
    }

    /// A small spring embedder, deterministic from the term ids: nodes
    /// repel, ties attract in proportion to their weight, and a few dozen
    /// rounds settle connected terms near each other.
    private func arrange(in size: CGSize) {
        guard !nodes.isEmpty else { return }
        let width = max(size.width, 400)
        let height = max(size.height, 300)
        var place: [String: CGPoint] = [:]
        for node in nodes {
            let hash = Self.stableHash(node.id)
            place[node.id] = CGPoint(x: 60 + Double(hash % 1000) / 1000 * (width - 120),
                                     y: 60 + Double((hash / 1000) % 1000) / 1000 * (height - 140))
        }
        let ideal = min(width, height) / Double(max(nodes.count, 2)).squareRoot() * 0.9
        let maxWeight = edges.map(\.weight).max() ?? 1
        for _ in 0..<120 {
            var force: [String: CGVector] = [:]
            // Repulsion between every pair.
            for i in nodes.indices {
                for j in nodes.indices where j > i {
                    let a = nodes[i].id, b = nodes[j].id
                    guard let pa = place[a], let pb = place[b] else { continue }
                    var dx = pa.x - pb.x, dy = pa.y - pb.y
                    var distance = max(hypot(dx, dy), 0.1)
                    if distance < 0.5 { dx = 1; dy = 1; distance = 1.4 }
                    let push = ideal * ideal / distance
                    let unit = CGVector(dx: dx / distance, dy: dy / distance)
                    force[a, default: .init()].dx += unit.dx * push
                    force[a, default: .init()].dy += unit.dy * push
                    force[b, default: .init()].dx -= unit.dx * push
                    force[b, default: .init()].dy -= unit.dy * push
                }
            }
            // Attraction along the ties, the heavier the closer.
            for edge in edges {
                guard let pa = place[edge.a], let pb = place[edge.b] else { continue }
                let dx = pb.x - pa.x, dy = pb.y - pa.y
                let distance = max(hypot(dx, dy), 0.1)
                let pull = distance * distance / ideal * (0.4 + 0.6 * edge.weight / maxWeight)
                let unit = CGVector(dx: dx / distance, dy: dy / distance)
                force[edge.a, default: .init()].dx += unit.dx * pull
                force[edge.a, default: .init()].dy += unit.dy * pull
                force[edge.b, default: .init()].dx -= unit.dx * pull
                force[edge.b, default: .init()].dy -= unit.dy * pull
            }
            for node in nodes {
                guard let position = place[node.id], let push = force[node.id] else { continue }
                let magnitude = max(hypot(push.dx, push.dy), 0.1)
                let step = min(magnitude, 12.0)
                place[node.id] = CGPoint(
                    x: min(max(position.x + push.dx / magnitude * step, 70), width - 70),
                    y: min(max(position.y + push.dy / magnitude * step, 50), height - 90))
            }
        }
        positions = place
    }

    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    }
}

extension GlossarySpaceView {
    /// Glossary Space as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "glossary-space",
        name: "Glossary Space",
        systemImage: "point.3.connected.trianglepath.dotted",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(GlossarySpaceView()) },
        hidesDocumentList: true
    )
}
