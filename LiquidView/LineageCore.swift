import Foundation
import CoreGraphics

// Lineage — the citation web of the books on the shelf, built from the
// papers themselves: every shelf book is a node, and so is every work
// its references name, deduplicated across the collection by DOI (else
// by title). Edges run from the citing paper to the cited work, so a
// proceedings sits at its year and its intellectual lineage spreads
// back through time, shared ancestors growing with each citation.
//
// This file is the platform-agnostic core — model, layout, trace,
// search, palette. Foundation and CoreGraphics only; no AppKit, no
// SwiftUI, so the same code feeds the Mac window, the phone, and a
// visionOS scene. LineageView.swift is the shared SwiftUI face.

/// One paper's worth of input — platform-neutral, derived from an
/// `EPUBRecord` and its structured import on whichever platform.
nonisolated struct LineagePaper: Sendable, Hashable {
    let id: String
    let title: String
    let authors: [String]
    let year: Int?
    let doi: String?
    let venue: String?
    /// The paper's bibliography, one verbatim BibTeX record per entry.
    let referenceBibTeX: [String]

    /// The graph's input for a shelf: every book paired with its
    /// structured import (for the references), keyed by record id.
    static func fromShelf(records: [EPUBRecord],
                          docs: [String: LiquidDoc]) -> [LineagePaper] {
        records.map { record in
            let doc = docs[record.id]
            let iso = record.dateISO ?? doc?.date?.isoString
            let year = iso.flatMap { Int($0.prefix(4)) }
            return LineagePaper(
                id: record.id,
                title: record.title,
                authors: record.authorList,
                year: year,
                doi: record.doi,
                venue: record.venue,
                referenceBibTeX: doc?.references.map(\.bibtex) ?? [])
        }
    }
}

/// The web itself: nodes (shelf papers and the works they cite),
/// cleaned edges, and the year columns. Built once per shelf change,
/// off the main actor — see `LineageGraph.build`.
nonisolated struct LineageGraph: Sendable {

    struct Node: Sendable, Identifiable {
        let id: String            // shelf record id, or "cited:<key>"
        let index: Int            // dense index into `nodes`
        let title: String
        let authorsShort: String  // "Bernstein", "Lupi et al."
        let authorsFull: String
        let year: Int
        let doi: String?
        let venue: String?
        /// True for books on the shelf; false for works known only as
        /// references. Shelf nodes open in the reader; cited-only nodes
        /// show what the collection's bibliographies say about them.
        let onShelf: Bool
        var cites: [Int] = []
        var citedBy: [Int] = []
        /// Sizing weight: how many papers in the collection cite it.
        var weight: Int { citedBy.count }
    }

    struct Edge: Sendable, Hashable {
        let source: Int   // the citing paper
        let target: Int   // the cited work
    }

    let nodes: [Node]
    let edges: [Edge]
    let years: [Int]              // sorted, only years present
    let byYear: [Int: [Int]]      // year → node indices
    let collectionName: String
    /// References that could not join the web (no parsable year or no
    /// title) — surfaced so a sparse web is explained, never silent.
    let droppedReferences: Int
    let shelfCount: Int

    // MARK: Building

    /// DOI normalised to bare lowercase form ("10.1145/…").
    static func normalizedDOI(_ raw: String?) -> String? {
        guard var doi = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !doi.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/",
                       "https://dx.doi.org/", "http://dx.doi.org/", "doi:"] {
            if doi.hasPrefix(prefix) { doi = String(doi.dropFirst(prefix.count)) }
        }
        return doi.isEmpty ? nil : doi
    }

    /// Title reduced to a matching key: case- and diacritic-folded,
    /// alphanumerics only, so punctuation and BibTeX braces never
    /// split what is the same work.
    static func titleKey(_ title: String) -> String {
        title.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: nil)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// "Surname" or "Surname et al." from a BibTeX author field or a
    /// display-name list.
    static func shortAuthors(_ names: [String]) -> String {
        guard let first = names.first, !first.isEmpty else { return "" }
        let surname: String
        if first.contains(",") {
            surname = first.split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? first
        } else {
            surname = first.split(separator: " ").last.map(String.init) ?? first
        }
        return names.count > 1 ? "\(surname) et al." : surname
    }

    static func build(papers: [LineagePaper],
                      collectionName: String) -> LineageGraph {
        var nodes: [Node] = []
        var byDOI: [String: Int] = [:]
        var byTitle: [String: Int] = [:]
        var dropped = 0

        func register(_ node: Node, doi: String?, title: String) {
            if let doi, byDOI[doi] == nil { byDOI[doi] = node.index }
            let key = titleKey(title)
            if !key.isEmpty, byTitle[key] == nil { byTitle[key] = node.index }
        }

        // Shelf papers first, so a reference naming a shelf book
        // resolves to the book, never to a duplicate cited-only node.
        var shelfCount = 0
        var indexByPaperID: [String: Int] = [:]
        for paper in papers {
            guard let year = paper.year else { dropped += 1; continue }
            indexByPaperID[paper.id] = nodes.count
            let doi = normalizedDOI(paper.doi)
            let node = Node(
                id: paper.id, index: nodes.count, title: paper.title,
                authorsShort: shortAuthors(paper.authors),
                authorsFull: paper.authors.joined(separator: ", "),
                year: year, doi: doi, venue: paper.venue, onShelf: true)
            nodes.append(node)
            register(node, doi: doi, title: paper.title)
            shelfCount += 1
        }

        // Then every reference: resolve to an existing node by DOI,
        // else by title; else become a new cited-only node.
        var edgeSet = Set<Edge>()
        for paper in papers {
            guard let source = indexByPaperID[paper.id] else { continue }
            for bibtex in paper.referenceBibTeX {
                guard let record = BibTeXRecord.records(in: bibtex).first
                else { dropped += 1; continue }
                let doi = normalizedDOI(record.fields["doi"])
                let key = titleKey(record.title)
                var target: Int?
                if let doi { target = byDOI[doi] }
                if target == nil, !key.isEmpty { target = byTitle[key] }
                if target == nil {
                    let digits = record.year.prefix { $0.isNumber }
                    guard let year = Int(digits), !record.title.isEmpty
                    else { dropped += 1; continue }
                    let names = record.author
                        .components(separatedBy: " and ")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let node = Node(
                        id: "cited:" + (doi ?? key),
                        index: nodes.count, title: record.title,
                        authorsShort: shortAuthors(names),
                        authorsFull: record.displayAuthors,
                        year: year, doi: doi,
                        venue: record.fields["booktitle"] ?? record.fields["journal"],
                        onShelf: false)
                    nodes.append(node)
                    register(node, doi: doi, title: record.title)
                    target = node.index
                }
                if let target, target != source {
                    edgeSet.insert(Edge(source: source, target: target))
                }
            }
        }

        let edges = edgeSet.sorted {
            ($0.source, $0.target) < ($1.source, $1.target)
        }
        for edge in edges {
            nodes[edge.source].cites.append(edge.target)
            nodes[edge.target].citedBy.append(edge.source)
        }
        // Sort keys snapshotted first: sorting `nodes[i].cites` writes
        // into `nodes`, so the comparator must not read `nodes` itself.
        let ages = nodes.map { ($0.year, $0.title) }
        let byAge: (Int, Int) -> Bool = { ages[$0] < ages[$1] }
        for index in nodes.indices {
            nodes[index].cites.sort(by: byAge)
            nodes[index].citedBy.sort(by: byAge)
        }

        var byYear: [Int: [Int]] = [:]
        for node in nodes { byYear[node.year, default: []].append(node.index) }

        return LineageGraph(
            nodes: nodes, edges: edges,
            years: byYear.keys.sorted(), byYear: byYear,
            collectionName: collectionName,
            droppedReferences: dropped, shelfCount: shelfCount)
    }
}

/// Column layout: x linear on year, dots sized by in-collection
/// citations, each year's column stacked symmetrically about the
/// vertical centre with the heaviest dots in the middle. Deterministic:
/// same graph and size, same positions.
nonisolated struct LineageLayout: Sendable {

    struct Insets: Sendable {
        var leading: CGFloat = 48
        var trailing: CGFloat = 48
        var top: CGFloat = 110
        var bottom: CGFloat = 84
    }

    struct Positions: Sendable {
        var points: [CGPoint]
        var radii: [CGFloat]
        var xForYear: [Int: CGFloat]
        var centerY: CGFloat
        var yearSpacing: CGFloat
    }

    static func layout(graph: LineageGraph, size: CGSize,
                       insets: Insets = Insets()) -> Positions {
        let count = graph.nodes.count
        var points = [CGPoint](repeating: .zero, count: count)
        var radii = [CGFloat](repeating: 0, count: count)
        let centerY = insets.top + (size.height - insets.top - insets.bottom) / 2
        guard count > 0, let minYear = graph.years.first,
              let maxYear = graph.years.last else {
            return Positions(points: points, radii: radii, xForYear: [:],
                             centerY: centerY, yearSpacing: 0)
        }

        // x: ordinal over the years present, with empty runs kept — but
        // compressed to at most four slots, so short gaps stay visible
        // as history while one eighteenth-century reference cannot
        // crush the modern columns into slivers.
        let left = insets.leading
        let right = size.width - insets.trailing
        var unitForYear: [Int: CGFloat] = [:]
        var unit: CGFloat = 0
        var previous: Int?
        for year in graph.years {
            if let previous { unit += CGFloat(min(year - previous, 4)) }
            unitForYear[year] = unit
            previous = year
        }
        let totalUnits = max(unit, 1)
        let spacing = (right - left) / totalUnits
        var xForYear: [Int: CGFloat] = [:]
        for year in graph.years {
            xForYear[year] = maxYear == minYear
                ? (left + right) / 2
                : left + (unitForYear[year] ?? 0) / totalUnits * (right - left)
        }

        // Radius: r = (1.7 + 1.05√w)·rs, rs clamped so the largest dot
        // stays inside 46 % of the column spacing.
        let maxWeight = graph.nodes.map(\.weight).max() ?? 0
        let unscaledMax = 1.7 + 1.05 * sqrt(CGFloat(maxWeight))
        var rs = min(max(spacing * 0.46 / unscaledMax, 0.35), 1.35)

        func radius(_ weight: Int, scale: CGFloat) -> CGFloat {
            (1.7 + 1.05 * sqrt(CGFloat(weight))) * scale
        }

        // Column order: weight descending then title, distributed
        // alternately front/back so columns taper toward both ends.
        var columns: [Int: [Int]] = [:]
        for (year, indices) in graph.byYear {
            let sorted = indices.sorted {
                let a = graph.nodes[$0], b = graph.nodes[$1]
                if a.weight != b.weight { return a.weight > b.weight }
                return a.title < b.title
            }
            var ordered: [Int] = []
            for (rank, index) in sorted.enumerated() {
                if rank.isMultiple(of: 2) { ordered.insert(index, at: 0) }
                else { ordered.append(index) }
            }
            columns[year] = ordered
        }

        // Vertical: gap 3·gs, gs the largest value (0.5…8) for which
        // every column fits 90 % of the height; shrink dots if the
        // tallest column still cannot fit at the smallest gap.
        let availableHeight = size.height - insets.top - insets.bottom
        func columnHeight(_ ordered: [Int], gs: CGFloat, scale: CGFloat) -> CGFloat {
            let dots = ordered.reduce(CGFloat(0)) {
                $0 + 2 * radius(graph.nodes[$1].weight, scale: scale)
            }
            return dots + 3 * gs * CGFloat(max(ordered.count - 1, 0))
        }
        func tallest(gs: CGFloat, scale: CGFloat) -> CGFloat {
            columns.values.reduce(0) {
                max($0, columnHeight($1, gs: gs, scale: scale))
            }
        }
        var gs: CGFloat = 8
        while gs > 0.5, tallest(gs: gs, scale: rs) > availableHeight * 0.9 {
            gs -= 0.25
        }
        while tallest(gs: gs, scale: rs) > availableHeight * 0.92, rs > 0.1 {
            rs *= 0.92
        }

        for (year, ordered) in columns {
            let x = xForYear[year] ?? (left + right) / 2
            let total = columnHeight(ordered, gs: gs, scale: rs)
            var y = centerY - total / 2
            for index in ordered {
                let r = radius(graph.nodes[index].weight, scale: rs)
                points[index] = CGPoint(x: x, y: y + r)
                radii[index] = r
                y += 2 * r + 3 * gs
            }
        }

        return Positions(points: points, radii: radii, xForYear: xForYear,
                         centerY: centerY, yearSpacing: spacing)
    }

    /// The edge's cubic control points — the same bow as the web
    /// reference implementation.
    static func controlPoints(from source: CGPoint, to target: CGPoint,
                              centerY: CGFloat) -> (CGPoint, CGPoint) {
        let dx = source.x - target.x
        let mid = (source.y + target.y) / 2
        let dir: CGFloat = mid < centerY ? -1 : 1
        let bow = dir * min(abs(dx) * 0.12, 90) * (abs(mid - centerY) < 40 ? 0.5 : 1)
        return (CGPoint(x: source.x - dx * 0.42, y: source.y + bow),
                CGPoint(x: target.x + dx * 0.42, y: target.y + bow))
    }
}

/// Lineage of one node: what it drew on (backwards over `cites`) and
/// what built on it (forwards over `citedBy`), out to three steps.
nonisolated enum LineageTrace {

    struct Trace: Sendable {
        let root: Int
        /// depth 0…3; direction −1 roots, +1 influence, 0 the root.
        let nodes: [Int: (depth: Int, direction: Int)]
        let edges: [(source: Int, target: Int, depth: Int, direction: Int)]
    }

    static let maxDepth = 3

    static func trace(from root: Int, in graph: LineageGraph) -> Trace {
        var found: [Int: (depth: Int, direction: Int)] = [root: (0, 0)]
        var edges: [(Int, Int, Int, Int)] = []

        // Backwards first (matching the reference implementation): a
        // node reachable both ways keeps its first discovery.
        for direction in [-1, 1] {
            var frontier = [root]
            var depth = 0
            while !frontier.isEmpty, depth < maxDepth {
                depth += 1
                var next: [Int] = []
                for index in frontier {
                    let neighbours = direction == -1
                        ? graph.nodes[index].cites
                        : graph.nodes[index].citedBy
                    for neighbour in neighbours {
                        // Edges kept in citation direction: source cites target.
                        let edge = direction == -1
                            ? (index, neighbour, depth, direction)
                            : (neighbour, index, depth, direction)
                        edges.append(edge)
                        if found[neighbour] == nil {
                            found[neighbour] = (depth, direction)
                            next.append(neighbour)
                        }
                    }
                }
                frontier = next
            }
        }
        return Trace(root: root, nodes: found, edges: edges)
    }
}

/// Live substring search over title + authors, case- and
/// diacritic-insensitive.
nonisolated enum LineageSearch {
    static func matches(_ query: String, in graph: LineageGraph) -> [Int] {
        let folded = query.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
        guard folded.count >= 2 else { return [] }
        return graph.nodes.filter {
            ($0.title + " " + $0.authorsFull)
                .folding(options: [.diacriticInsensitive, .caseInsensitive],
                         locale: nil)
                .contains(folded)
        }.map(\.index)
    }
}

/// The palette, once, as hex — the UI layers map these to their own
/// colour types so every platform shows the same lineage.
nonisolated enum LineageStyle {
    static let paper: UInt32 = 0xF3F4F1
    static let paperDark: UInt32 = 0x1B1C1E
    static let ink: UInt32 = 0x17181A
    static let inkDark: UInt32 = 0xECEDEA
    static let graphite: UInt32 = 0x3B3F46
    static let graphiteDark: UInt32 = 0x9BA0A8
    static let muted: UInt32 = 0x70747A
    static let roots: UInt32 = 0x2743C4      // ultramarine — what it drew on
    static let influence: UInt32 = 0xC4791C  // ochre — what built on it

    /// Alpha and width ramps per bloom depth (index 1…3).
    static let edgeAlpha: [CGFloat] = [0, 0.90, 0.30, 0.11]
    static let edgeWidth: [CGFloat] = [0, 1.2, 0.75, 0.6]
    static let nodeAlpha: [CGFloat] = [1, 1, 0.55, 0.30]
    static let restingEdgeAlpha: CGFloat = 0.11
    static let restingEdgeAlphaDark: CGFloat = 0.16
    static let dimmedBaseAlpha: CGFloat = 0.22
}
