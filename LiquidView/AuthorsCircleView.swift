import SwiftUI

/// Author's Circle: the community as people, not documents. Everyone sits
/// still around a ring — portrait when the contact record has one,
/// initials otherwise — in the system's own colors. Click a person and
/// their correspondence appears: lines in the label color to the authors
/// they have replied to, gray lines from the authors who have replied,
/// commented, or otherwise written in relation to them. ⌘A selects
/// everyone and shows the whole mesh. The more documents behind a line,
/// the thicker it runs; rest the pointer on a line and a card lists the
/// documents behind it — the card stays put so any of them can be clicked
/// open. Click empty space to dismiss it.
struct AuthorsCircleView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedAuthor: String?
    @State private var allSelected = false
    /// The line whose documents are on display; set by hover, kept until
    /// another line takes over, the background is clicked, or the
    /// selection changes.
    @State private var activeEdgeID: String?
    /// Where the card sits: frozen at the point the line was first
    /// hovered, so it doesn't chase the pointer.
    @State private var panelPoint: CGPoint = .zero

    private struct AuthorNode: Identifiable {
        let name: String
        let documents: Int
        var id: String { name }
    }

    /// One directed line: documents by `from` that link to documents by
    /// `to` — the documents themselves ride along for the hover card.
    private struct Edge: Identifiable {
        let from: String
        let to: String
        let docs: [LiquidDoc]
        var id: String { "\(from)→\(to)" }
    }

    /// A drawn line, ready for stroking and for pointer hit-testing.
    private struct Segment {
        let edge: Edge
        let a: CGPoint
        let b: CGPoint
    }

    var body: some View {
        let authors = authors
        if authors.count < 2 {
            ContentUnavailableView(
                "Not Enough Authors",
                systemImage: "person.2",
                description: Text("Author's Circle appears once the library holds letters from at least two people."))
        } else {
            circle(authors: authors)
        }
    }

    private func circle(authors: [AuthorNode]) -> some View {
        GeometryReader { geometry in
            let positions = positions(for: authors, in: geometry.size)
            let segments = segments(in: positions)
            ZStack {
                Canvas { context, _ in
                    for segment in segments {
                        stroke(segment, in: &context)
                    }
                }
                .allowsHitTesting(false)

                ForEach(authors) { author in
                    authorButton(author)
                        .position(positions[author.name] ?? .zero)
                }

                if selectedAuthor == nil && !allSelected {
                    Text("Click an author to see their circle — ⌘A for everyone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }

                if let segment = segments.first(where: { $0.edge.id == activeEdgeID }) {
                    edgePanel(segment.edge, in: geometry.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { activeEdgeID = nil }
            .onContinuousHover { phase in
                guard case .active(let point) = phase else { return }
                if let hit = nearestSegment(to: point, in: segments),
                   hit.edge.id != activeEdgeID {
                    activeEdgeID = hit.edge.id
                    panelPoint = point
                }
                // Off every line the card stays: it must survive the
                // pointer's journey onto it.
            }
            // ⌘A, without needing focus: an unseen button carries the
            // standard Select All shortcut for this view.
            .background(
                Button("") { selectEveryone() }
                    .keyboardShortcut("a", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func selectEveryone() {
        allSelected = true
        selectedAuthor = nil
        activeEdgeID = nil
    }

    private func authorButton(_ author: AuthorNode) -> some View {
        let isSelected = author.name == selectedAuthor || allSelected
        return Button {
            if selectedAuthor == author.name {
                selectedAuthor = nil
            } else {
                selectedAuthor = author.name
            }
            allSelected = false
            activeEdgeID = nil
        } label: {
            VStack(spacing: 3) {
                PersonAvatarView(name: author.name, size: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 44 * 0.18, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    )
                Text(author.name)
                    .font(.caption2)
                    .fontWeight(author.name == selectedAuthor ? .bold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: 90)
            }
        }
        .buttonStyle(.plain)
        .help("\(author.name) — \(author.documents) documents")
    }

    /// The card behind a line: who to whom, and every document that made
    /// it — each one clickable. It stays until another line is hovered,
    /// the background is clicked, or the selection changes.
    private func edgePanel(_ edge: Edge, in size: CGSize) -> some View {
        let limit = 10
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(edge.from) → \(edge.to)")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    activeEdgeID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            ForEach(edge.docs.prefix(limit), id: \.id) { doc in
                Button {
                    model.openInLibrary(doc)
                } label: {
                    Text(doc.title)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open “\(doc.title)”")
            }
            if edge.docs.count > limit {
                Text("and \(edge.docs.count - limit) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .position(x: min(max(panelPoint.x, 150), size.width - 150),
                  y: max(panelPoint.y - 60, 70))
    }

    // MARK: Data

    /// Everyone with documents in the visible library, most prolific first.
    private var authors: [AuthorNode] {
        let byAuthor = Dictionary(grouping: model.filteredEntries, by: { $0.doc.creditedAuthor })
        return byAuthor
            .map { AuthorNode(name: $0.key, documents: $0.value.count) }
            .sorted { ($0.documents, $1.name) > ($1.documents, $0.name) }
    }

    /// Every directed author-to-author line in the visible library: the
    /// documents by `from` that link to documents by `to`, newest first.
    /// A document counts toward a line once.
    private var allEdges: [Edge] {
        let entries = model.filteredEntries
        let authorOf: [String: String] = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.doc.id, $0.doc.creditedAuthor) })
        var docsByPair: [String: (from: String, to: String, docs: [LiquidDoc])] = [:]
        for entry in entries {
            let doc = entry.doc
            let counterparts = Set(doc.links.compactMap { link -> String? in
                guard !LiquidAddress.isPersonAddress(link.to),
                      let target = authorOf[LiquidAddress.canonical(link.to)],
                      target != doc.author else { return nil }
                return target
            })
            for counterpart in counterparts {
                let key = "\(doc.author)→\(counterpart)"
                docsByPair[key, default: (doc.author, counterpart, [])].docs.append(doc)
            }
        }
        return docsByPair.values.map { pair in
            Edge(from: pair.from, to: pair.to,
                 docs: pair.docs.sorted { $0.listedDate > $1.listedDate })
        }
    }

    /// What is on display: everything when everyone is selected, else the
    /// selected author's correspondence in both directions.
    private var visibleEdges: [Edge] {
        if allSelected { return allEdges }
        guard let selected = selectedAuthor else { return [] }
        return allEdges.filter { $0.from == selected || $0.to == selected }
    }

    // MARK: Geometry

    private func positions(for authors: [AuthorNode], in size: CGSize) -> [String: CGPoint] {
        let radius = min(size.width, size.height) / 2 - 70
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var positions: [String: CGPoint] = [:]
        for (index, author) in authors.enumerated() {
            // Start at the top; no rotation — the circle holds still.
            let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(authors.count)
            positions[author.name] = CGPoint(x: center.x + radius * cos(angle),
                                             y: center.y + radius * sin(angle))
        }
        return positions
    }

    /// The lines to draw right now, pulled back from the portraits and
    /// nudged sideways so the two directions between the same pair stay
    /// distinguishable.
    private func segments(in positions: [String: CGPoint]) -> [Segment] {
        visibleEdges.compactMap { edge in
            guard let from = positions[edge.from], let to = positions[edge.to] else { return nil }
            let d = hypot(to.x - from.x, to.y - from.y)
            guard d > 1 else { return nil }
            let unit = CGPoint(x: (to.x - from.x) / d, y: (to.y - from.y) / d)
            let normal = CGPoint(x: -unit.y, y: unit.x)
            let side: CGFloat = edge.from < edge.to ? 3 : -3
            let margin: CGFloat = 30
            let a = CGPoint(x: from.x + unit.x * margin + normal.x * side,
                            y: from.y + unit.y * margin + normal.y * side)
            let b = CGPoint(x: to.x - unit.x * margin + normal.x * side,
                            y: to.y - unit.y * margin + normal.y * side)
            return Segment(edge: edge, a: a, b: b)
        }
    }

    private func nearestSegment(to point: CGPoint, in segments: [Segment]) -> Segment? {
        var best: (segment: Segment, distance: CGFloat)?
        for segment in segments {
            let d = distance(from: point, toSegment: segment.a, segment.b)
            if d < 7, d < (best?.distance ?? .infinity) {
                best = (segment, d)
            }
        }
        return best?.segment
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared))
        return hypot(p.x - (a.x + ab.x * t), p.y - (a.y + ab.y * t))
    }

    // MARK: Drawing

    private func stroke(_ segment: Segment, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: segment.a)
        path.addLine(to: segment.b)
        let isActive = segment.edge.id == activeEdgeID
        // Weight carries the count; the colors stay the system's. With one
        // author selected, their replies run in the label color and what
        // comes toward them in gray; with everyone selected the mesh is
        // uniform.
        let width = 1 + min(CGFloat(segment.edge.docs.count), 7) + (isActive ? 1.5 : 0)
        let color: Color = if let selected = selectedAuthor, segment.edge.from == selected {
            .primary.opacity(isActive ? 1 : 0.8)
        } else if selectedAuthor != nil {
            .gray.opacity(isActive ? 0.95 : 0.55)
        } else {
            .primary.opacity(isActive ? 0.9 : 0.45)
        }
        context.stroke(path, with: .color(color), lineWidth: width)
    }
}

extension AuthorsCircleView {
    /// Author's Circle as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "authors-circle",
        name: "Author's Circle",
        systemImage: "person.crop.circle.badge.checkmark",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(AuthorsCircleView()) },
        hidesDocumentList: true
    )
}
