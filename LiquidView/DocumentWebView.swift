import SwiftUI

/// The connected-documents view: an ego-centered radial map of the web
/// around the current document. Documents are cards, connections are typed
/// colored edges with direction. Click a card to re-center, double-click to
/// read it, click an edge's dot to read that pair in transpointing view.
struct DocumentWebView: View {
    @Environment(AppModel.self) private var model

    private var centerID: String? {
        if let id = model.current?.doc.id, model.index.byID[id] != nil { return id }
        return model.index.timeline.last?.id
    }

    private var web: DocumentWeb? {
        guard let centerID else { return nil }
        return WebBuilder.web(centeredOn: centerID,
                              byID: model.index.byID,
                              backlinks: model.index.backlinks)
    }

    @State private var isOpenView = false

    var body: some View {
        Group {
            if let web {
                if isOpenView {
                    WebSpaceView(docs: spaceDocs(for: web))
                } else {
                    mapView(for: web)
                }
            } else {
                ContentUnavailableView(
                    "No Documents",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Open a document, or add documents to the community folder.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $isOpenView) {
                    Text("Closed").tag(false)
                    Text("Open").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Closed: a map of connected documents. Open: the documents themselves as columns, with lines to the exact cited passages.")
            }
        }
    }

    /// The center and its direct connections, as full documents for the
    /// open (columns-in-space) view.
    private func spaceDocs(for web: DocumentWeb) -> [LiquidDoc] {
        let center = web.nodes.first { $0.ring == 0 }.map { [$0.entry.doc] } ?? []
        let ringOne = web.nodes.filter { $0.ring == 1 }.prefix(4).map { $0.entry.doc }
        return center + ringOne
    }

    private func mapView(for web: DocumentWeb) -> some View {
        GeometryReader { proxy in
            let positions = layout(web: web, in: proxy.size)
            ZStack {
                edgeLayer(web: web, positions: positions)
                ghostLayer(web: web, positions: positions)
                edgeDotLayer(web: web, positions: positions)
                ForEach(web.nodes) { node in
                    card(for: node)
                        .position(positions[node.id]
                                  ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2))
                }
            }
        }
        .overlay(alignment: .bottom) { legend(for: web) }
    }

    // MARK: - Layout

    private func layout(web: DocumentWeb, in size: CGSize) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        positions[web.centerID] = center
        let radiusOne = min(size.width, size.height) * 0.30
        let radiusTwo = min(size.width, size.height) * 0.46

        func point(angle: Double, radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle)))
        }

        let ringOne = web.nodes.filter { $0.ring == 1 }
        let slots = ringOne.count + web.unresolvedTargets.count
        var angleByID: [String: Double] = [:]
        if slots > 0 {
            for (index, node) in ringOne.enumerated() {
                let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(slots)
                positions[node.id] = point(angle: angle, radius: radiusOne)
                angleByID[node.id] = angle
            }
            for (offset, ghost) in web.unresolvedTargets.enumerated() {
                let index = ringOne.count + offset
                let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(slots)
                positions["ghost:\(ghost)"] = point(angle: angle, radius: radiusOne)
            }
        }

        // Ring two fans out around its parent's angle.
        let grouped = Dictionary(grouping: web.nodes.filter { $0.ring == 2 },
                                 by: { $0.parentID ?? "" })
        for (parentID, children) in grouped {
            let base = angleByID[parentID] ?? (-Double.pi / 2)
            let step = 0.34
            for (index, child) in children.enumerated() {
                let offset = (Double(index) - Double(children.count - 1) / 2) * step
                positions[child.id] = point(angle: base + offset, radius: radiusTwo)
            }
        }
        return positions
    }

    // MARK: - Layers

    private func edgeLayer(web: DocumentWeb, positions: [String: CGPoint]) -> some View {
        ForEach(web.edges) { edge in
            if let from = positions[edge.fromID], let to = positions[edge.toID],
               let path = Self.edgePath(from: from, to: to) {
                path.stroke(RelStyle.color(for: edge.rel).opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func ghostLayer(web: DocumentWeb, positions: [String: CGPoint]) -> some View {
        ForEach(web.unresolvedTargets, id: \.self) { target in
            if let ghostPosition = positions["ghost:\(target)"],
               let from = positions[web.centerID] {
                ZStack {
                    if let path = Self.edgePath(from: from, to: ghostPosition) {
                        path.stroke(Color.secondary.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    }
                }
                Text(target)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.secondary.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                    .position(ghostPosition)
                    .help("Cited by the center document but not in the community folder yet")
            }
        }
    }

    private func edgeDotLayer(web: DocumentWeb, positions: [String: CGPoint]) -> some View {
        ForEach(web.edges) { edge in
            if let from = positions[edge.fromID], let to = positions[edge.toID] {
                let jitter = CGFloat(edge.ordinal % 3 - 1) * 7
                Button {
                    openPair(edge)
                } label: {
                    Circle()
                        .fill(RelStyle.color(for: edge.rel))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .padding(6)   // generous click target
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .position(x: (from.x + to.x) / 2 + jitter, y: (from.y + to.y) / 2 + jitter)
                .help("\(edge.rel ?? "link") — click to read both in parallel")
            }
        }
    }

    // MARK: - Cards

    private func card(for node: DocumentWeb.Node) -> some View {
        VStack(spacing: 2) {
            Text(node.entry.doc.title)
                .font(.system(size: node.ring == 0 ? 14 : 12, design: .serif))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(node.entry.doc.displayAuthor)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: node.ring == 0 ? 170 : 140)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(node.ring == 0 ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: node.ring == 0 ? 2 : 1)
        )
        .opacity(node.ring == 2 ? 0.82 : 1)
        .gesture(
            TapGesture(count: 2)
                .onEnded { model.openInLibrary(node.entry.doc) }
                .exclusively(before: TapGesture().onEnded {
                    if node.ring != 0 { model.open(node.entry.doc) }
                })
        )
        .help(node.ring == 0
              ? "Double-click to read"
              : "Click to re-center · double-click to read")
    }

    // MARK: - Actions and chrome

    private func openPair(_ edge: DocumentWeb.Edge) {
        guard let from = model.index.byID[edge.fromID],
              let to = model.index.byID[edge.toID] else { return }
        model.openTranspointing(from: from.doc, to: to.doc)
    }

    private func legend(for web: DocumentWeb) -> some View {
        let rels = Array(Set(web.edges.map { $0.rel ?? "link" })).sorted()
        return HStack(spacing: 12) {
            Text("\(web.nodes.count) documents · \(web.edges.count) connections")
            ForEach(rels, id: \.self) { rel in
                HStack(spacing: 4) {
                    Circle()
                        .fill(RelStyle.color(for: rel == "link" ? nil : rel))
                        .frame(width: 7, height: 7)
                    Text(rel)
                }
            }
            Text("click to re-center · double-click to read · dot for parallel")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 10)
    }

    // MARK: - Geometry

    /// A straight edge shortened at both ends so it meets card borders, with
    /// an arrowhead showing link direction.
    private static func edgePath(from: CGPoint, to: CGPoint, shorten: CGFloat = 54) -> Path? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > shorten * 2 + 8 else { return nil }
        let ux = dx / length
        let uy = dy / length
        let start = CGPoint(x: from.x + ux * shorten, y: from.y + uy * shorten)
        let end = CGPoint(x: to.x - ux * shorten, y: to.y - uy * shorten)

        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(uy, ux)
        let arrow: CGFloat = 7
        let left = CGPoint(x: end.x - arrow * CGFloat(cos(angle - 0.5)),
                           y: end.y - arrow * CGFloat(sin(angle - 0.5)))
        let right = CGPoint(x: end.x - arrow * CGFloat(cos(angle + 0.5)),
                            y: end.y - arrow * CGFloat(sin(angle + 0.5)))
        path.move(to: left)
        path.addLine(to: end)
        path.addLine(to: right)
        return path
    }
}

extension DocumentWebView {
    /// The Connections view as an exchangeable module: document list in the
    /// content column, the web (map or columns-in-space) as the detail.
    @MainActor static let module = LibraryViewModule(
        id: "connections",
        name: "Connections",
        systemImage: "point.3.connected.trianglepath.dotted",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(DocumentWebView()) },
        hidesDocumentList: true
    )
}

/// The open view: full documents standing as columns in space, with lines
/// running to the exact passages that are cited — as Ted Nelson draws it.
struct WebSpaceView: View {
    @Environment(AppModel.self) private var model
    let docs: [LiquidDoc]

    var body: some View {
        let connections = ParallelReading.spaceConnections(among: docs)
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(docs) { doc in
                    ParallelColumnView(doc: doc,
                                       anchorPrefix: doc.id,
                                       highlights: highlights(for: doc, connections: connections))
                        .frame(width: 340)
                        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(doc.id == docs.first?.id
                                        ? Color.accentColor.opacity(0.7)
                                        : Color.secondary.opacity(0.25),
                                        lineWidth: doc.id == docs.first?.id ? 1.5 : 1)
                        )
                }
            }
            .padding(24)
        }
        .overlayPreferenceValue(ParagraphAnchorKey.self) { anchors in
            SpaceBeamLayer(connections: connections, anchors: anchors)
                .allowsHitTesting(false)
        }
        .clipped()
        .overlay(alignment: .bottom) {
            if !connections.isEmpty {
                Text(connections.count == 1
                     ? "1 connection between these documents"
                     : "\(connections.count) connections between these documents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
    }

    private func highlights(for doc: LiquidDoc, connections: [SpaceConnection]) -> [String: Color] {
        var result: [String: Color] = [:]
        for connection in connections {
            if connection.fromDocID == doc.id, let paragraphID = connection.fromParagraphID {
                result[paragraphID] = RelStyle.color(for: connection.rel)
            }
            if connection.toDocID == doc.id, let paragraphID = connection.toParagraphID {
                result[paragraphID] = RelStyle.color(for: connection.rel)
            }
        }
        return result
    }
}

/// Draws paragraph-precise beams among any number of document columns.
struct SpaceBeamLayer: View {
    let connections: [SpaceConnection]
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            ForEach(connections) { connection in
                if let fromAnchor = anchors["\(connection.fromDocID):\(connection.fromParagraphID ?? "#header")"],
                   let toAnchor = anchors["\(connection.toDocID):\(connection.toParagraphID ?? "#header")"] {
                    beamPath(from: proxy[fromAnchor], to: proxy[toAnchor])
                        .stroke(RelStyle.color(for: connection.rel).opacity(0.5),
                                style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                }
            }
        }
    }

    private func beamPath(from: CGRect, to: CGRect) -> Path {
        // Leave from the edge facing the target column.
        let leftToRight = from.midX <= to.midX
        let start = CGPoint(x: leftToRight ? from.maxX : from.minX, y: from.midY)
        let end = CGPoint(x: leftToRight ? to.minX : to.maxX, y: to.midY)
        let bend = max(24, abs(end.x - start.x) * 0.4) * (leftToRight ? 1 : -1)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + bend, y: start.y),
                      control2: CGPoint(x: end.x - bend, y: end.y))
        path.addEllipse(in: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
        path.addEllipse(in: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
        return path
    }
}
