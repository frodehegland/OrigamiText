import SwiftUI

/// Transpointing windows: two connected documents side by side with visible
/// beams drawn between the linked passages. The beams track scrolling via
/// anchor preferences reported by each paragraph.
struct ParallelReadingView: View {
    @Environment(AppModel.self) private var model
    let leftDoc: LiquidDoc
    let rightDoc: LiquidDoc
    /// Flow: dense text broken open for reading — display only, both sides.
    @State private var flowText = false

    private var connections: [ParallelConnection] {
        ParallelReading.connections(left: leftDoc, right: rightDoc)
    }

    var body: some View {
        let connections = connections
        HStack(spacing: 0) {
            ParallelColumnView(doc: leftDoc, anchorPrefix: "L",
                               highlights: highlights(for: connections, side: .left),
                               flowed: flowText)
            Divider()
            ParallelColumnView(doc: rightDoc, anchorPrefix: "R",
                               highlights: highlights(for: connections, side: .right),
                               flowed: flowText)
        }
        .overlayPreferenceValue(ParagraphAnchorKey.self) { anchors in
            BeamLayer(connections: connections, anchors: anchors)
                .allowsHitTesting(false)
        }
        .clipped()
        .overlay(alignment: .bottom) {
            legend(for: connections)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    withAnimation(.snappy) { flowText.toggle() }
                } label: {
                    Label(flowText ? "Unflow" : "Flow", systemImage: "text.alignleft")
                }
                .help("Break dense text open while reading: sentences get their own lines, clauses break after commas, parentheses stand apart — the documents themselves are untouched")
            }
            ToolbarItem {
                Button {
                    model.exitParallel()
                } label: {
                    Label("Exit Parallel Reading", systemImage: "xmark.circle")
                }
                .help("Return to single-document reading")
            }
        }
    }

    private func highlights(for connections: [ParallelConnection],
                            side: ParallelConnection.Owner) -> [String: Color] {
        var result: [String: Color] = [:]
        for connection in connections {
            let paragraphID = (side == .left) ? connection.leftParagraphID : connection.rightParagraphID
            if let paragraphID {
                result[paragraphID] = RelStyle.color(for: connection.rel)
            }
        }
        return result
    }

    @ViewBuilder
    private func legend(for connections: [ParallelConnection]) -> some View {
        let rels = Array(Set(connections.map { $0.rel ?? "link" })).sorted()
        if !connections.isEmpty {
            HStack(spacing: 12) {
                Text(connections.count == 1 ? "1 connection" : "\(connections.count) connections")
                ForEach(rels, id: \.self) { rel in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(RelStyle.color(for: rel == "link" ? nil : rel))
                            .frame(width: 7, height: 7)
                        Text(rel)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 10)
        }
    }
}

/// Colors for link relationship types, shared by beams and highlights.
enum RelStyle {
    static func color(for rel: String?) -> Color {
        switch rel {
        case "cites": .blue
        case "responds-to": .green
        case "revises": .orange
        case "relates-to": .purple
        case "extends": .teal
        case "supports": .mint
        case "questions": .yellow
        case "summarizes": .indigo
        case "disagrees-with", "retracts": .red
        default: .gray
        }
    }
}

/// Paragraph frames reported upward so the beam layer can find both ends
/// of every connection. Keys are "L:<paragraphID>", "R:<paragraphID>",
/// and "L:#header" / "R:#header".
struct ParagraphAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// One side of the parallel view: the document with connected paragraphs
/// tinted and edge-marked in the relationship color.
struct ParallelColumnView: View {
    let doc: LiquidDoc
    let anchorPrefix: String
    let highlights: [String: Color]
    var flowed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DocumentHeader(doc: doc)
                    .anchorPreference(key: ParagraphAnchorKey.self, value: .bounds) {
                        ["\(anchorPrefix):#header": $0]
                    }
                    .padding(.bottom, 16)

                if let body = doc.body {
                    ForEach(body) { paragraph in
                        ParagraphView(paragraph: paragraph, isHighlighted: false,
                                      flowed: flowed)
                            .background(
                                (highlights[paragraph.id] ?? .clear).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .overlay(alignment: .leading) {
                                if let color = highlights[paragraph.id] {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(color)
                                        .frame(width: 3)
                                        .padding(.vertical, 6)
                                        .offset(x: -7)
                                }
                            }
                            .anchorPreference(key: ParagraphAnchorKey.self, value: .bounds) {
                                ["\(anchorPrefix):\(paragraph.id)": $0]
                            }
                    }
                } else if let wraps = doc.wraps {
                    Label("Wraps “\(wraps.file)”", systemImage: "doc.richtext")
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
            .padding(18)
        }
    }
}

/// Draws the transpointing beams between anchor pairs.
struct BeamLayer: View {
    let connections: [ParallelConnection]
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            ForEach(connections) { connection in
                if let path = beamPath(for: connection, in: proxy) {
                    path.stroke(
                        RelStyle.color(for: connection.rel).opacity(0.5),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                }
            }
        }
    }

    private func beamPath(for connection: ParallelConnection, in proxy: GeometryProxy) -> Path? {
        guard let leftAnchor = anchors["L:\(connection.leftParagraphID ?? "#header")"],
              let rightAnchor = anchors["R:\(connection.rightParagraphID ?? "#header")"] else { return nil }
        let leftRect = proxy[leftAnchor]
        let rightRect = proxy[rightAnchor]
        let start = CGPoint(x: leftRect.maxX, y: leftRect.midY)
        let end = CGPoint(x: rightRect.minX, y: rightRect.midY)
        let bend = max(30, (end.x - start.x) * 0.4)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end,
                      control1: CGPoint(x: start.x + bend, y: start.y),
                      control2: CGPoint(x: end.x - bend, y: end.y))
        // Endpoint dots make it obvious exactly which passages are joined.
        path.addEllipse(in: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
        path.addEllipse(in: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
        return path
    }
}
