import SwiftUI

// Lineage — the shared face over LineageCore: years as columns, papers
// as dots sized by in-collection citations, citations as faint arcs.
// Hover (or tap) blooms a work's lineage — ultramarine backwards to
// what it drew on, ochre forwards to what built on it, three steps,
// fading with distance. A click locks the selection and opens the
// detail panel. The same view runs on the Mac, the phone, and the
// headset; the platform wrappers at the bottom of this file only
// gather the shelf and say how to open a book.

struct LineageView: View {
    let papers: [LineagePaper]
    let collectionName: String
    /// Opens a shelf book in the platform's reader; nil hides the button.
    var openPaper: ((String) -> Void)? = nil
    /// Previews and tests set this false so the first frame is the
    /// finished web, not the intro's opening blank.
    var introEnabled = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var graph: LineageGraph?
    @State private var hoverIndex: Int?
    @State private var hoverPoint: CGPoint?
    @State private var selectedIndex: Int?
    @State private var backStack: [Int] = []
    @State private var searchText = ""
    @State private var introStart: Date?
    @State private var cachedTrace: LineageTrace.Trace?

    /// The intro plays once per app session, on the first web shown.
    @MainActor private static var introPlayed = false

    private let panelWidth: CGFloat = 360

    var body: some View {
        Group {
            if let graph {
                if graph.nodes.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Trace Yet",
                        systemImage: "point.3.filled.connected.trianglepath.dotted",
                        description: Text("Open some papers first — the lineage view draws every book on the shelf and every work their references name."))
                } else {
                    web(graph)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(color(colorScheme == .dark ? LineageStyle.paperDark
                                               : LineageStyle.paper))
        .task(id: papers) {
            let input = papers
            let name = collectionName
            let built = await Task.detached(priority: .userInitiated) {
                LineageGraph.build(papers: input, collectionName: name)
            }.value
            graph = built
            hoverIndex = nil
            if let selected = selectedIndex, selected >= built.nodes.count {
                select(nil)
            }
            if introEnabled, !Self.introPlayed, !reduceMotion,
               built.years.count > 1, selectedIndex == nil {
                Self.introPlayed = true
                introStart = Date()
            }
        }
        // The intro clears itself once its timeline has fully played.
        .task(id: introStart) {
            guard introStart != nil, let graph else { return }
            try? await Task.sleep(for: .seconds(introDuration(graph) + 0.2))
            if !Task.isCancelled { introStart = nil }
        }
    }

    // MARK: The web

    private func web(_ graph: LineageGraph) -> some View {
        GeometryReader { geo in
            let panelOpen = selectedIndex != nil && !usesSheet
            let canvasWidth = max(geo.size.width - (panelOpen ? panelWidth : 0), 200)
            let canvasSize = CGSize(width: canvasWidth, height: geo.size.height)
            HStack(spacing: 0) {
                canvasArea(graph, size: canvasSize)
                    .frame(width: canvasWidth, height: geo.size.height)
                    .clipped()
                if panelOpen, let selected = selectedIndex {
                    Divider()
                    detailPanel(graph, index: selected)
                        .frame(width: panelWidth - 1)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: panelOpen)
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { usesSheet && selectedIndex != nil },
            set: { if !$0 { select(nil) } })) {
            if let selected = selectedIndex {
                detailPanel(graph, index: selected)
                    .presentationDetents([.medium, .large])
            }
        }
        #endif
        #if os(macOS)
        .onExitCommand { select(nil) }
        #endif
    }

    private func canvasArea(_ graph: LineageGraph, size: CGSize) -> some View {
        let positions = LineageLayout.layout(graph: graph, size: size)
        let matches = Set(LineageSearch.matches(searchText, in: graph))
        let searching = !matches.isEmpty
            || searchText.trimmingCharacters(in: .whitespaces).count >= 2
        return ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 60,
                                    paused: introStart == nil)) { timeline in
                Canvas { context, canvasSize in
                    draw(&context, size: canvasSize, graph: graph,
                         positions: positions, matches: matches,
                         searching: searching, now: timeline.date)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard introStart == nil else { return }
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    hoverIndex = hitTest(point, graph: graph,
                                         positions: positions)
                case .ended:
                    hoverPoint = nil
                    hoverIndex = nil
                }
                refreshTrace(graph)
            }
            .onTapGesture(coordinateSpace: .local) { point in
                if introStart != nil { introStart = nil; return }
                select(hitTest(point, graph: graph, positions: positions))
                refreshTrace(graph)
            }

            masthead(graph)
                .padding(.top, 14)
                .padding(.leading, 18)

            searchField(graph)
                .padding(.top, 14)
                .padding(.trailing, 18)
                .frame(maxWidth: .infinity, alignment: .topTrailing)

            statusLine(graph, matchCount: matches.count, searching: searching)
                .padding(.leading, 18)
                .padding(.bottom, 58)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomLeading)

            if let hover = hoverIndex, let point = hoverPoint,
               selectedIndex == nil, introStart == nil {
                tooltip(graph.nodes[hover])
                    .position(tooltipPosition(point, in: size))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: State moves

    private func select(_ index: Int?) {
        if let current = selectedIndex, let index, index != current {
            backStack.append(current)
        }
        if index == nil { backStack.removeAll() }
        selectedIndex = index
    }

    private func refreshTrace(_ graph: LineageGraph) {
        let root = selectedIndex ?? hoverIndex
        guard let root else { cachedTrace = nil; return }
        if cachedTrace?.root != root {
            cachedTrace = LineageTrace.trace(from: root, in: graph)
        }
    }

    private func hitTest(_ point: CGPoint, graph: LineageGraph,
                         positions: LineageLayout.Positions) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in graph.nodes.indices {
            let p = positions.points[index]
            let reach = positions.radii[index] + 6
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= reach, d < (best?.distance ?? .infinity) {
                best = (index, d)
            }
        }
        return best?.index
    }

    private var usesSheet: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize,
                      graph: LineageGraph,
                      positions: LineageLayout.Positions,
                      matches: Set<Int>, searching: Bool, now: Date) {
        let dark = colorScheme == .dark
        let ink = color(dark ? LineageStyle.inkDark : LineageStyle.ink)
        let graphite = color(dark ? LineageStyle.graphiteDark
                                  : LineageStyle.graphite)
        let restingEdge = dark ? LineageStyle.restingEdgeAlphaDark
                               : LineageStyle.restingEdgeAlpha
        let trace = (selectedIndex ?? hoverIndex) != nil ? cachedTrace : nil
        let focused = trace != nil || searching
        let elapsed = introStart.map { now.timeIntervalSince($0) }

        // Base: every edge, every node — dimmed while a lineage or a
        // search has the floor.
        var base = context
        if focused { base.opacity = LineageStyle.dimmedBaseAlpha }
        for edge in graph.edges {
            let fraction = introEdgeFraction(sourceYear: graph.nodes[edge.source].year,
                                             graph: graph, elapsed: elapsed)
            guard fraction > 0 else { continue }
            let path = edgePath(edge, positions: positions, fraction: fraction)
            base.stroke(path, with: .color(graphite.opacity(restingEdge)),
                        lineWidth: 0.8)
        }
        for node in graph.nodes {
            let pop = introPopScale(year: node.year, graph: graph,
                                    elapsed: elapsed)
            guard pop > 0 else { continue }
            let fill = node.onShelf ? ink.opacity(0.82)
                                    : graphite.opacity(0.62)
            base.fill(dot(at: positions.points[node.index],
                          radius: positions.radii[node.index] * pop),
                      with: .color(fill))
        }

        drawAxis(&context, size: size, graph: graph, positions: positions,
                 ink: ink)

        // Search rings.
        if searching {
            let roots = color(LineageStyle.roots)
            for index in matches {
                let p = positions.points[index]
                let r = positions.radii[index]
                context.fill(dot(at: p, radius: r * 1.1), with: .color(ink))
                context.stroke(dot(at: p, radius: r + 3.5),
                               with: .color(roots), lineWidth: 1.2)
            }
        }

        // The bloom: influence then roots, deep before near, then the
        // nodes by depth, then the root itself.
        if let trace {
            let roots = color(LineageStyle.roots)
            let influence = color(LineageStyle.influence)
            for direction in [1, -1] {
                let hue = direction == -1 ? roots : influence
                for depth in stride(from: LineageTrace.maxDepth, through: 1, by: -1) {
                    for edge in trace.edges
                    where edge.direction == direction && edge.depth == depth {
                        let path = edgePath(
                            LineageGraph.Edge(source: edge.source,
                                              target: edge.target),
                            positions: positions, fraction: 1)
                        context.stroke(
                            path,
                            with: .color(hue.opacity(LineageStyle.edgeAlpha[depth])),
                            lineWidth: LineageStyle.edgeWidth[depth])
                    }
                }
            }
            for depth in stride(from: LineageTrace.maxDepth, through: 1, by: -1) {
                for (index, mark) in trace.nodes
                where mark.depth == depth {
                    let hue = mark.direction == -1 ? roots : influence
                    context.fill(
                        dot(at: positions.points[index],
                            radius: positions.radii[index]),
                        with: .color(hue.opacity(LineageStyle.nodeAlpha[depth])))
                }
            }
            let rootPoint = positions.points[trace.root]
            let rootRadius = positions.radii[trace.root]
            context.fill(dot(at: rootPoint, radius: rootRadius * 1.35),
                         with: .color(ink))
            context.stroke(dot(at: rootPoint, radius: rootRadius + 4),
                           with: .color(ink), lineWidth: 1)
        }
    }

    private func drawAxis(_ context: inout GraphicsContext, size: CGSize,
                          graph: LineageGraph,
                          positions: LineageLayout.Positions, ink: Color) {
        guard let minYear = graph.years.first,
              let maxYear = graph.years.last, maxYear > minYear else { return }
        let spacing = positions.yearSpacing
        let muted = color(LineageStyle.muted)
        let axisY = size.height - 40
        for year in graph.years {
            guard let x = positions.xForYear[year] else { continue }
            let isEndpoint = year == minYear || year == maxYear
            let isMajor = year.isMultiple(of: 5) || isEndpoint
            let label: String?
            if spacing >= 34 {
                label = isMajor ? String(year)
                                : String(format: "%02d", year % 100)
            } else if spacing >= 14 {
                label = isMajor ? String(year) : nil
            } else {
                label = (year.isMultiple(of: 10) || isEndpoint)
                    ? String(year) : nil
            }
            guard let label else { continue }
            let text = Text(label)
                .font(.caption2)
                .foregroundStyle(isMajor ? ink.opacity(0.75)
                                         : muted.opacity(0.8))
            context.draw(text, at: CGPoint(x: x, y: axisY), anchor: .top)
        }
    }

    private func dot(at point: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2))
    }

    private func edgePath(_ edge: LineageGraph.Edge,
                          positions: LineageLayout.Positions,
                          fraction: CGFloat) -> Path {
        let source = positions.points[edge.source]
        let target = positions.points[edge.target]
        let (c1, c2) = LineageLayout.controlPoints(
            from: source, to: target, centerY: positions.centerY)
        var path = Path()
        if fraction >= 1 {
            path.move(to: source)
            path.addCurve(to: target, control1: c1, control2: c2)
            return path
        }
        // Partial draw for the intro: the cubic sampled as a polyline.
        let steps = 28
        let upto = max(Int(CGFloat(steps) * fraction), 1)
        path.move(to: source)
        for step in 1...upto {
            let t = CGFloat(step) / CGFloat(steps)
            path.addLine(to: cubicPoint(source, c1, c2, target, t: t))
        }
        return path
    }

    private func cubicPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint,
                            _ p3: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x
        let y = u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y
        return CGPoint(x: x, y: y)
    }

    // MARK: Intro timing

    private func yearRank(_ year: Int, in graph: LineageGraph) -> Int {
        graph.years.firstIndex(of: year) ?? 0
    }

    /// Years start 230 ms apart — squeezed when the collection reaches
    /// far back, so the whole draw never runs much past eight seconds.
    private func introStagger(_ graph: LineageGraph) -> TimeInterval {
        min(0.23, 8.0 / Double(max(graph.years.count, 1)))
    }

    private func introDuration(_ graph: LineageGraph) -> TimeInterval {
        introStagger(graph) * Double(max(graph.years.count - 1, 0)) + 0.84
    }

    /// 0 → not yet popped; grows past 1 briefly (overshoot) then rests at 1.
    private func introPopScale(year: Int, graph: LineageGraph,
                               elapsed: TimeInterval?) -> CGFloat {
        guard let elapsed else { return 1 }
        let start = introStagger(graph) * Double(yearRank(year, in: graph))
        let progress = (elapsed - start) / 0.38
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        let x = CGFloat(progress)
        let c1: CGFloat = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    private func introEdgeFraction(sourceYear: Int, graph: LineageGraph,
                                   elapsed: TimeInterval?) -> CGFloat {
        guard let elapsed else { return 1 }
        let start = introStagger(graph) * Double(yearRank(sourceYear, in: graph)) + 0.12
        let progress = (elapsed - start) / 0.72
        return CGFloat(min(max(progress, 0), 1))
    }

    // MARK: Chrome

    private func masthead(_ graph: LineageGraph) -> some View {
        let citedOnly = graph.nodes.count - graph.shelfCount
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(graph.collectionName)
                    .font(.title2)
                    .fontDesign(.serif)
                if !reduceMotion, graph.years.count > 1, introStart == nil {
                    Button("Replay") { introStart = Date() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Every paper in this collection, and every work their references name.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(counted(graph.shelfCount, "paper")) · \(counted(citedOnly, "cited work")) · \(counted(graph.edges.count, "citation"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .allowsHitTesting(introStart == nil)
    }

    private func searchField(_ graph: LineageGraph) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Find a work", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 170)
                .onSubmit {
                    let matches = LineageSearch.matches(searchText, in: graph)
                    if let best = matches.max(by: {
                        graph.nodes[$0].weight < graph.nodes[$1].weight
                    }) {
                        select(best)
                        refreshTrace(graph)
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }

    private func statusLine(_ graph: LineageGraph, matchCount: Int,
                            searching: Bool) -> some View {
        let roots = color(LineageStyle.roots)
        let influence = color(LineageStyle.influence)
        let line: Text
        if introStart != nil {
            line = Text("The collection draws year by year. Tap anywhere to skip.")
        } else if searching {
            line = matchCount == 0
                ? Text("No works match.")
                : Text("\(counted(matchCount, "work")) match\(matchCount == 1 ? "es" : ""). Return opens the most cited.")
        } else {
            line = Text("Hover or tap a work to see ")
                + Text("\u{25CF} what it drew on").foregroundStyle(roots)
                + Text(" and ")
                + Text("\u{25CF} what built on it").foregroundStyle(influence)
                + Text(", out to three steps.")
        }
        return line
            .font(.caption)
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
    }

    private func tooltip(_ node: LineageGraph.Node) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.title)
                .font(.callout)
                .fontDesign(.serif)
                .lineLimit(2)
            Text("\(node.authorsShort) · \(String(node.year))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Cites \(node.cites.count) · cited by \(node.citedBy.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4, y: 2)
    }

    private func tooltipPosition(_ cursor: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(max(cursor.x + 30, 150), size.width - 150),
                y: max(cursor.y - 52, 46))
    }

    // MARK: Detail panel

    private func detailPanel(_ graph: LineageGraph, index: Int) -> some View {
        LineageDetailPanel(
            graph: graph,
            index: index,
            canGoBack: !backStack.isEmpty,
            onBack: {
                if let previous = backStack.popLast() {
                    selectedIndex = previous
                    refreshTrace(graph)
                }
            },
            onSelect: { next in
                select(next)
                refreshTrace(graph)
            },
            onOpen: openPaper,
            onClose: { select(nil) })
    }

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// The right-hand inspector (a sheet on the phone): where the work
/// appeared, who wrote it, the way out to the DOI, and its lineage as
/// navigable lists — ultramarine for what it drew on, ochre for what
/// built on it.
private struct LineageDetailPanel: View {
    let graph: LineageGraph
    let index: Int
    let canGoBack: Bool
    let onBack: () -> Void
    let onSelect: (Int) -> Void
    let onOpen: ((String) -> Void)?
    let onClose: () -> Void

    @State private var rootsExpanded = false
    @State private var influenceExpanded = false

    private var node: LineageGraph.Node { graph.nodes[index] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    if canGoBack {
                        Button {
                            onBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let venue = node.venue, !venue.isEmpty {
                    (Text(node.onShelf ? "In this collection — " : "Cited from ")
                        + Text(venue).italic())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !node.onShelf {
                    Text("Known from this collection's references.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(node.title)
                    .font(.title2)
                    .fontDesign(.serif)
                    .textSelection(.enabled)

                Text(node.authorsFull.isEmpty ? String(node.year)
                     : "\(node.authorsFull) · \(String(node.year))")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if node.onShelf, let onOpen {
                    Button {
                        onOpen(node.id)
                    } label: {
                        Label("Open in Reader", systemImage: "book")
                    }
                }

                if let doi = node.doi,
                   let url = URL(string: "https://doi.org/\(doi)") {
                    Link("Read at doi.org", destination: url)
                        .font(.callout)
                }

                lineageList(
                    title: "Drew on \(counted(node.cites.count, "work")) in this web",
                    empty: "Drew on no works in this web.",
                    indices: node.cites,
                    hex: LineageStyle.roots,
                    expanded: $rootsExpanded)

                lineageList(
                    title: "Built on by \(counted(node.citedBy.count, "paper")) here",
                    empty: "No paper in this collection cites it — yet.",
                    indices: node.citedBy,
                    hex: LineageStyle.influence,
                    expanded: $influenceExpanded)

                Divider()
                Text("\(graph.collectionName) — \(counted(graph.shelfCount, "paper")) and the works their references name.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lineageList(title: String, empty: String, indices: [Int],
                             hex: UInt32,
                             expanded: Binding<Bool>) -> some View {
        let tint = Color(red: Double((hex >> 16) & 0xFF) / 255,
                         green: Double((hex >> 8) & 0xFF) / 255,
                         blue: Double(hex & 0xFF) / 255)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(indices.isEmpty ? empty : title)
                    .font(.subheadline.weight(.medium))
            }
            let shown = expanded.wrappedValue ? indices
                                              : Array(indices.prefix(8))
            ForEach(shown, id: \.self) { other in
                let entry = graph.nodes[other]
                Button {
                    onSelect(other)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text("\(entry.authorsShort), \(String(entry.year))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if indices.count > 8, !expanded.wrappedValue {
                Button("and \(indices.count - 8) more") {
                    expanded.wrappedValue = true
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

/// "1 paper", "2 papers" — the counts lines read like sentences.
private func counted(_ count: Int, _ noun: String) -> String {
    count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
}

// MARK: - Preview

#Preview("Lineage", traits: .fixedLayout(width: 1200, height: 800)) {
    // A small synthetic proceedings: recent papers drawing on shared
    // ancestors, enough structure to see columns, arcs, and weights.
    let ancestors: [(String, String, Int)] = [
        ("As We May Think", "Bush, Vannevar", 1945),
        ("Augmenting Human Intellect", "Engelbart, Douglas", 1962),
        ("Literary Machines", "Nelson, Ted", 1982),
        ("Patterns of Hypertext", "Bernstein, Mark", 1998),
        ("Hypertext as Method", "Atzenbeck, Claus and Nürnberg, Peter", 2019),
        ("Seven Hypertexts", "Anderson, Mark and Millard, David", 2023),
    ]
    let papers = (0..<14).map { number in
        let year = 2024 + number % 3
        let cited = ancestors.enumerated()
            .filter { ($0.offset + number).isMultiple(of: 2) || number % 4 == 0 }
            .map { entry in
                "@article{a\(entry.offset), title={\(entry.element.0)}, author={\(entry.element.1)}, year={\(entry.element.2)}}"
            }
        return LineagePaper(
            id: "paper-\(number)",
            title: "Study \(number + 1): Folding the Hypertext Record",
            authors: ["Author \(number + 1)"], year: year,
            doi: "10.1145/1.\(number)", venue: "ACM Hypertext",
            referenceBibTeX: cited)
    }
    return LineageView(papers: papers, collectionName: "Preview Proceedings",
                       introEnabled: false)
}

// MARK: - Platform wrappers

#if os(macOS)
/// The Mac's Lineage: a whole-library view module — the shelf's books
/// and everything they cite, opened from the sidebar's Views.
struct LineageModuleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LineageView(
            papers: LineagePaper.fromShelf(
                records: model.epubRecords,
                docs: model.index.byID.mapValues(\.doc)),
            collectionName: "Lineage",
            openPaper: { model.openEPUBRecord(withID: $0) })
    }

    static let module = LibraryViewModule(
        id: "lineage",
        name: "Lineage",
        systemImage: "point.3.filled.connected.trianglepath.dotted",
        makeContent: { AnyView(LineageModuleView()) },
        hidesDocumentList: true)
}
#endif

#if os(iOS)
/// The phone and pad's Lineage, a shelf tab: tap blooms and locks,
/// the panel arrives as a sheet on the phone.
struct PhoneLineageView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        LineageView(
            papers: LineagePaper.fromShelf(
                records: model.epubRecords,
                docs: model.index.byID.mapValues(\.doc)),
            collectionName: "Lineage",
            openPaper: { model.readerRecordID = $0 })
    }
}
#endif

#if os(visionOS)
/// The headset's Lineage window, opened from the shelf panel.
struct VisionLineageWindow: View {
    @Environment(VisionModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LineageView(
            papers: LineagePaper.fromShelf(
                records: model.epubRecords,
                docs: model.index.byID.mapValues(\.doc)),
            collectionName: "Lineage",
            openPaper: { openWindow(id: "reader", value: $0) })
    }
}
#endif
