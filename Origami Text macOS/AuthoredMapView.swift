#if os(macOS)
import SwiftUI

/// What a book's own records add to its authored map beyond the document:
/// each node's label (the map's `nodes` list), and which views declare a
/// y-up space (§10.3), so they are drawn the right way up.
struct AuthoredMapExtras: Sendable {
    var labels: [String: String] = [:]
    var yUpViews: Set<String> = []
}

/// The author's own arrangement of the document (Profile 1.0 §10.3): the
/// map views written into the book, drawn as the writer placed them. It is
/// the author's, never the reader's — nothing here moves a node or writes
/// back (§15). A click on a passage opens it in the reading; a click on a
/// concept shows its definition.
struct AuthoredMapView: View {
    let doc: LiquidDoc
    let extras: AuthoredMapExtras
    /// Opens a passage of the document (a paragraph or heading id).
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewIndex = 0
    @State private var selected: String?

    /// One node as drawn: its label, what it is, and where the writer put it.
    private struct Node: Identifiable {
        enum Kind { case concept, heading, passage, reference, other }
        let id: String
        let label: String
        let kind: Kind
        let point: CGPoint
        /// The paragraph it opens, when it is a passage of the document.
        let paragraphID: String?
        let detail: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Author\u{2019}s Map").font(.headline)
                Text(doc.title).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if doc.layouts.count > 1 {
                    Picker("View", selection: $viewIndex) {
                        ForEach(Array(doc.layouts.enumerated()), id: \.offset) { index, layout in
                            Text(layout.name).tag(index)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let layout = doc.layouts[safe: viewIndex], !layout.positions.isEmpty {
                plane(for: layout)
            } else {
                ContentUnavailableView(
                    "No Map in This Document",
                    systemImage: "map",
                    description: Text("The author did not include an arranged map. A map made in Author travels inside the EPUB and appears here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let selected, let node = nodes(for: doc.layouts[safe: viewIndex])
                .first(where: { $0.id == selected }), let detail = node.detail {
                Divider()
                Text(detail)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    /// The plane: the writer's coordinates fitted to the window, the
    /// connections drawn beneath the nodes they join.
    private func plane(for layout: LiquidDoc.Layout) -> some View {
        GeometryReader { proxy in
            let placed = nodes(for: layout)
            let fitted = fit(placed, in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    for connection in doc.mapConnections {
                        guard let from = fitted[connection.from],
                              let to = fitted[connection.to] else { continue }
                        var path = Path()
                        path.move(to: from)
                        path.addLine(to: to)
                        context.stroke(path, with: .color(.secondary.opacity(0.6)), lineWidth: 1.2)
                    }
                }
                ForEach(placed) { node in
                    card(node)
                        .position(fitted[node.id] ?? .zero)
                }
            }
        }
        .padding(8)
    }

    private func card(_ node: Node) -> some View {
        Text(node.label)
            .font(node.kind == .heading ? .callout.bold() : .callout)
            .italic(node.kind == .reference)
            .lineLimit(3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 180)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                // Opaque underneath, so connections pass behind the card.
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                    if node.kind == .concept {
                        RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.14))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected == node.id ? Color.accentColor : Color.secondary.opacity(0.35),
                                  lineWidth: selected == node.id ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture {
                selected = node.id
                if let paragraphID = node.paragraphID {
                    dismiss()
                    onOpen(paragraphID)
                }
            }
            .help(node.paragraphID != nil ? "Open this passage" : (node.detail ?? node.label))
    }

    /// The view's nodes, each named from what the document knows of it:
    /// the map's own label, a concept, a heading or passage, a reference.
    private func nodes(for layout: LiquidDoc.Layout?) -> [Node] {
        guard let layout else { return [] }
        let body = doc.body ?? []
        let yUp = extras.yUpViews.contains(layout.sourceID ?? layout.name)
        return layout.positions.map { position in
            let ref = position.id
            let bare = ref.split(separator: "#").last.map(String.init) ?? ref
            let point = CGPoint(x: position.x, y: yUp ? -position.y : position.y)
            if let concept = doc.concepts.first(where: { $0.id == ref || $0.id == bare }) {
                return Node(id: ref, label: extras.labels[ref] ?? concept.name, kind: .concept,
                            point: point, paragraphID: nil,
                            detail: concept.description.isEmpty ? nil : concept.description)
            }
            if let paragraph = body.first(where: { $0.id == ref })
                ?? AnnotationAnchor.sameElement(ref, in: body) {
                let words = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let short = words.count > 90 ? String(words.prefix(90)) + "\u{2026}" : words
                return Node(id: ref, label: extras.labels[ref] ?? short,
                            kind: paragraph.heading != nil ? .heading : .passage,
                            point: point, paragraphID: paragraph.id, detail: nil)
            }
            if let reference = doc.references.first(where: { $0.id == ref || $0.id == bare }) {
                return Node(id: ref, label: extras.labels[ref] ?? reference.citedAs ?? ref,
                            kind: .reference, point: point, paragraphID: nil,
                            detail: reference.bibtex)
            }
            return Node(id: ref, label: extras.labels[ref] ?? ref, kind: .other,
                        point: point, paragraphID: nil, detail: nil)
        }
    }

    /// The writer's coordinates are unitless (§10.3): scaled uniformly to
    /// fill the plane, keeping the arrangement's proportions.
    private func fit(_ nodes: [Node], in size: CGSize) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let xs = nodes.map(\.point.x), ys = nodes.map(\.point.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let margin: CGFloat = 110
        let width = max(size.width - margin * 2, 1), height = max(size.height - margin * 2, 1)
        let spanX = maxX - minX, spanY = maxY - minY
        let scale = min(spanX > 0 ? width / spanX : .infinity,
                        spanY > 0 ? height / spanY : .infinity)
        let s = scale.isFinite ? scale : 1
        let offsetX = (size.width - spanX * s) / 2, offsetY = (size.height - spanY * s) / 2
        var out: [String: CGPoint] = [:]
        for node in nodes {
            out[node.id] = CGPoint(x: offsetX + (node.point.x - minX) * s,
                                   y: offsetY + (node.point.y - minY) * s)
        }
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
