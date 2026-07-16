import SwiftUI

/// The Weave: the library with the figure and ground reversed — the
/// connections are the vital thing, the documents just knots on the
/// thread (6 July 2026 meeting: "the string, the connector is the vital
/// thing; the knot is just the thing on it"). Every document is a knot of
/// light on a slowly turning wheel, ordered by author and time; every
/// link is a thread across it, shading between its two authors' colors.
/// Hover a knot and its threads flare while the rest fall dark; drag to
/// spin; click a knot to read it. A provocation, not an instrument.
struct WeaveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let data = WeaveData.build(from: Array(model.index.byID.values),
                                   backlinks: model.index.backlinks)
        if data.nodes.isEmpty {
            ContentUnavailableView("Nothing to Weave",
                                   systemImage: "asterisk",
                                   description: Text("The Weave appears once the library holds documents."))
        } else {
            WeaveCanvas(data: data) { docID in
                if let entry = model.index.byID[docID] {
                    model.openInLibrary(entry.doc)
                }
            }
        }
    }
}

// MARK: - Data

struct WeaveNode: Identifiable {
    let id: String        // document id
    let title: String
    let author: String
    let weight: Int       // citations received — the knot's size
    let hue: Double       // the author's color
}

struct WeaveEdge {
    let from: Int
    let to: Int
}

struct WeaveData {
    var nodes: [WeaveNode] = []
    var edges: [WeaveEdge] = []
    /// Author label arcs: name, hue, and the node-index range they span.
    var authorArcs: [(name: String, hue: Double, range: ClosedRange<Int>)] = []

    static func build(from entries: [IndexEntry], backlinks: [String: [BacklinkRef]]) -> WeaveData {
        // Authors around the wheel, most prolific first; their documents
        // in creation order, so time runs along each author's arc.
        let byAuthor = Dictionary(grouping: entries, by: { $0.doc.author })
        let authors = byAuthor.keys.sorted {
            (byAuthor[$0]?.count ?? 0, $1) > (byAuthor[$1]?.count ?? 0, $0)
        }
        var data = WeaveData()
        var indexByID: [String: Int] = [:]
        for (authorIndex, author) in authors.enumerated() {
            let hue = Double(authorIndex) / Double(max(authors.count, 1))
            let docs = (byAuthor[author] ?? []).sorted { $0.doc.created < $1.doc.created }
            let start = data.nodes.count
            for entry in docs {
                indexByID[entry.doc.id] = data.nodes.count
                data.nodes.append(WeaveNode(id: entry.doc.id,
                                            title: entry.doc.title,
                                            author: author,
                                            weight: backlinks[entry.doc.id]?.count ?? 0,
                                            hue: hue))
            }
            if data.nodes.count > start {
                data.authorArcs.append((author, hue, start...(data.nodes.count - 1)))
            }
        }
        for entry in entries {
            guard let from = indexByID[entry.doc.id] else { continue }
            for link in entry.doc.links {
                guard let to = indexByID[LiquidAddress.canonical(link.to)], to != from else { continue }
                data.edges.append(WeaveEdge(from: from, to: to))
            }
        }
        data.edges = Array(data.edges.prefix(1200))   // stay legible and fast
        return data
    }
}

// MARK: - The wheel

struct WeaveCanvas: View {
    let data: WeaveData
    var onOpen: (String) -> Void = { _ in }
    /// The wheel's name, and what its resting center counts. The Lift
    /// Weave reuses the whole canvas under its own name.
    var title = "The Weave"
    var subtitle: String? = nil

    /// Ambient turn: one revolution every four minutes.
    private static let ambientSpeed = (2 * Double.pi) / 240
    private let born = Date.now

    @State private var hovered: Int?
    @State private var spun: Double = 0          // accumulated drag, radians
    @State private var dragDelta: Double = 0     // live drag, radians
    @State private var frameSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, at: timeline.date)
                }
            }
            .background(
                RadialGradient(colors: [Color(white: 0.09), .black],
                               center: .center, startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) / 1.2)
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = nearestNode(to: point, in: geometry.size, at: .now)
                case .ended:
                    hovered = nil
                }
            }
            .gesture(spinGesture(in: geometry.size))
            .gesture(SpatialTapGesture().onEnded { value in
                if let index = nearestNode(to: value.location, in: geometry.size, at: .now) {
                    onOpen(data.nodes[index].id)
                }
            })
            .onAppear { frameSize = geometry.size }
            .onChange(of: geometry.size) { frameSize = geometry.size }
            .overlay(alignment: .center) { centerLabel }
        }
        .navigationTitle(title)
    }

    /// The wheel's center speaks: the hovered knot, or the weave itself.
    private var centerLabel: some View {
        VStack(spacing: 4) {
            if let hovered, data.nodes.indices.contains(hovered) {
                let node = data.nodes[hovered]
                Text(node.title)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(.white)
                Text(node.author)
                    .font(.caption)
                    .foregroundStyle(color(hue: node.hue, brightness: 0.95))
            } else {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(3)
                    .foregroundStyle(.white.opacity(0.35))
                Text(subtitle ?? "\(data.nodes.count) knots · \(data.edges.count) threads")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 220)
        .allowsHitTesting(false)
    }

    // MARK: Geometry

    private func rotation(at date: Date) -> Double {
        Self.ambientSpeed * date.timeIntervalSince(born) + spun + dragDelta
    }

    private func ringRadius(in size: CGSize) -> Double {
        min(size.width, size.height) / 2 - 64
    }

    private func position(of index: Int, in size: CGSize, at date: Date) -> CGPoint {
        let angle = angleOf(index, at: date)
        let radius = ringRadius(in: size)
        return CGPoint(x: size.width / 2 + radius * cos(angle),
                       y: size.height / 2 + radius * sin(angle))
    }

    private func angleOf(_ index: Int, at date: Date) -> Double {
        rotation(at: date) + 2 * .pi * Double(index) / Double(max(data.nodes.count, 1))
    }

    private func nearestNode(to point: CGPoint, in size: CGSize, at date: Date) -> Int? {
        var best: (index: Int, distance: Double)?
        for index in data.nodes.indices {
            let p = position(of: index, in: size, at: date)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < 18, d < (best?.distance ?? .infinity) { best = (index, d) }
        }
        return best?.index
    }

    private func spinGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let start = atan2(value.startLocation.y - center.y, value.startLocation.x - center.x)
                let now = atan2(value.location.y - center.y, value.location.x - center.x)
                dragDelta = now - start
            }
            .onEnded { _ in
                spun += dragDelta
                dragDelta = 0
            }
    }

    private func color(hue: Double, brightness: Double, opacity: Double = 1) -> Color {
        Color(hue: hue, saturation: 0.62, brightness: brightness, opacity: opacity)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, at date: Date) {
        guard !data.nodes.isEmpty else { return }
        let t = date.timeIntervalSince(born)
        let connected = connectedSet()

        // Threads first — they are the vital thing. Unhovered: a breathing
        // field; hovered: everything else falls dark and its threads flare
        // through a blurred glow pass plus a crisp pass.
        for (i, edge) in data.edges.enumerated() {
            let isLit = hovered.map { edge.from == $0 || edge.to == $0 } ?? false
            if hovered != nil, !isLit {
                strokeThread(edge, in: &context, size: size, at: date, opacity: 0.05, width: 0.6)
            } else if !isLit {
                let breath = 0.30 + 0.14 * sin(t * 0.7 + Double(i) * 1.3)
                strokeThread(edge, in: &context, size: size, at: date, opacity: breath, width: 1.1)
            }
        }
        if hovered != nil {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 5))
                for edge in data.edges where edge.from == hovered || edge.to == hovered {
                    strokeThread(edge, in: &layer, size: size, at: date, opacity: 0.9, width: 3.5)
                }
            }
            for edge in data.edges where edge.from == hovered || edge.to == hovered {
                strokeThread(edge, in: &context, size: size, at: date, opacity: 1, width: 1.4)
            }
        }

        // The knots.
        for index in data.nodes.indices {
            let node = data.nodes[index]
            let p = position(of: index, in: size, at: date)
            let isHovered = index == hovered
            let isNeighbor = hovered.map { connected[$0]?.contains(index) ?? false } ?? false
            let dimmed = hovered != nil && !isHovered && !isNeighbor
            let radius = (2.0 + min(6, Double(node.weight).squareRoot() * 2)) * (isHovered ? 1.6 : 1)
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            if isHovered || isNeighbor {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 6))
                    layer.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                               with: .color(color(hue: node.hue, brightness: 1)))
                }
            }
            context.fill(Path(ellipseIn: rect),
                         with: .color(color(hue: node.hue,
                                            brightness: dimmed ? 0.35 : 0.95,
                                            opacity: dimmed ? 0.5 : 1)))
        }

        // Author names riding their arc of the ring, kept upright.
        let labelRadius = ringRadius(in: size) + 30
        for arc in data.authorArcs {
            let mid = (angleOf(arc.range.lowerBound, at: date) + angleOf(arc.range.upperBound, at: date)) / 2
            let p = CGPoint(x: size.width / 2 + labelRadius * cos(mid),
                            y: size.height / 2 + labelRadius * sin(mid))
            var rotated = context
            rotated.translateBy(x: p.x, y: p.y)
            var textAngle = mid + .pi / 2
            if sin(mid) > 0 { textAngle += .pi }
            rotated.rotate(by: .radians(textAngle))
            let dimmed = hovered != nil && data.nodes[hovered ?? 0].author != arc.name
            rotated.draw(Text(arc.name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(color(hue: arc.hue,
                                                   brightness: dimmed ? 0.4 : 0.9)),
                         at: .zero, anchor: .center)
        }
    }

    private func strokeThread(_ edge: WeaveEdge, in context: inout GraphicsContext,
                              size: CGSize, at date: Date, opacity: Double, width: Double) {
        let a = position(of: edge.from, in: size, at: date)
        let b = position(of: edge.to, in: size, at: date)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Chords bow toward the hub: far ends dive deep, near ends stay shallow.
        let control = CGPoint(x: center.x + (mid.x - center.x) * 0.35,
                              y: center.y + (mid.y - center.y) * 0.35)
        var path = Path()
        path.move(to: a)
        path.addQuadCurve(to: b, control: control)
        let fromColor = color(hue: data.nodes[edge.from].hue, brightness: 0.9, opacity: opacity)
        let toColor = color(hue: data.nodes[edge.to].hue, brightness: 0.9, opacity: opacity)
        context.stroke(path,
                       with: .linearGradient(Gradient(colors: [fromColor, toColor]),
                                             startPoint: a, endPoint: b),
                       lineWidth: width)
    }

    /// Which knots each knot touches, for neighbor lighting.
    private func connectedSet() -> [Int: Set<Int>] {
        var map: [Int: Set<Int>] = [:]
        for edge in data.edges {
            map[edge.from, default: []].insert(edge.to)
            map[edge.to, default: []].insert(edge.from)
        }
        return map
    }
}

extension WeaveView {
    /// The Weave as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "weave",
        name: "The Weave",
        systemImage: "asterisk",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(WeaveView()) },
        hidesDocumentList: true
    )
}

// MARK: - Preview with a synthetic community

#Preview("The Weave") {
    // Deterministic pseudo-community: six authors, forty knots, a weave
    // of threads — no library required.
    var data = WeaveData()
    let authors = ["Frode Hegland", "Mark Anderson", "Fabien Benetou",
                   "Peter Wasilko", "Tom Haymes", "Mohit"]
    var seed: UInt64 = 9
    func random(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int(seed >> 33) % bound
    }
    var start = 0
    for (i, author) in authors.enumerated() {
        let count = 4 + random(6)
        let hue = Double(i) / Double(authors.count)
        for d in 0..<count {
            data.nodes.append(WeaveNode(id: "\(i)-\(d)", title: "Document \(d + 1)",
                                        author: author, weight: random(9), hue: hue))
        }
        data.authorArcs.append((author, hue, start...(data.nodes.count - 1)))
        start = data.nodes.count
    }
    for _ in 0..<70 {
        let from = random(data.nodes.count)
        let to = random(data.nodes.count)
        if from != to { data.edges.append(WeaveEdge(from: from, to: to)) }
    }
    return WeaveCanvas(data: data)
        .frame(width: 720, height: 640)
}
