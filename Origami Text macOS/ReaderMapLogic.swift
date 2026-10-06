// THE READER'S MAP, WITHOUT THE PICTURE — Author's Map rules, ported.
//
// Everything here is pure: which concepts a selection lines up with,
// where the analysis views put the nodes, and what Align, Distribute,
// Sort, Gather and Z do to a set of centres. No views, no platform
// frameworks, so the macOS, iOS and visionOS maps can all draw from it.
//
// Every rule was carried over from Author (~/Documents/author_mac_forxcode)
// rather than re-imagined, and each function names the one it came from.
// Author's numbers are kept exactly: a column pitch of 170, a row pitch
// of 70, 40 between clusters, a 20pt gap when distributing, 20% and a
// 12pt gap per Gather, 40pt of padding and a 0.25× floor for Z.
//
// Coordinates follow Author's canvas: positions are node CENTRES relative
// to the middle of the canvas, with y pointing DOWN (CanvasView isFlipped).
//
// Two matching rules live side by side, as they do in Author, and they
// are deliberately not merged:
//   • The selection's lines (ReaderMapLinks) use updateGlossaryConnections'
//     rules — whole-word, sentence-level for solid lines; plain substring
//     for the light ones.
//   • The analysis views (ReaderMapLayouts.analysis) use AnalysisView's
//     referenceLinks — a plain substring test of every name (and each
//     comma-separated alternative longer than one character) against a
//     definition. That is what Author lays out by, so it is what we lay
//     out by, even where it disagrees with the lines.
import Foundation
import CoreGraphics

// MARK: - Model

/// One concept on the map. `size` is the node's drawn size in points;
/// the caller measures it, because Align, Distribute and Gather all
/// reason about edges and not just centres.
nonisolated struct ReaderMapNode: Identifiable, Hashable, Sendable {
    let id: String          // concept id
    let name: String        // label
    let definition: String
    var size: CGSize        // node's drawn size in points (caller supplies)
}

/// A line on the map.
nonisolated struct ReaderMapLink: Hashable, Sendable {
    /// Solid: the node whose definition mentions `to`. Light: the node
    /// whose definition mentions the selected node (`to`).
    let from: String
    let to: String
    /// true: outgoing "my definition mentions X" (whole-word,
    /// case-insensitive, sentence-level). false: incoming "X's definition
    /// mentions me" (Author's plain-substring rule).
    let solid: Bool
    /// The definition sentences that mention the other concept (solid
    /// links only; empty otherwise, and empty for a solid link found by
    /// Author's same-name fallback).
    let sentences: [String]
}

// MARK: - Links

nonisolated enum ReaderMapLinks {

    /// Links for the current selection, exactly as Author computes them in
    /// `CanvasViewController.updateGlossaryConnections`: for each selected
    /// node, outgoing solid links (`glossaryNodeLinksFrom`) and incoming
    /// light links (`glossaryNodeLinksTo`); a light link is dropped when
    /// the same pair already has a solid link. Pass all nodes on the map.
    ///
    /// Where this departs from Author, on purpose:
    ///   • Author checks for a solid twin only among the same selected
    ///     node's links, and then draws BOTH lines (the light one as solid)
    ///     on top of each other. Here a light link is dropped whenever the
    ///     pair — either direction — already has a solid link anywhere in
    ///     the result, which draws the same picture once.
    ///   • A node whose own definition contains its own name gave Author a
    ///     self-connection, which draws nothing useful; it is left out.
    ///   • Duplicate links (Author looks a node's entry up once by its
    ///     definition and again by its title, and so finds every link
    ///     twice) are collapsed to one.
    static func links(forSelection selected: Set<String>, among nodes: [ReaderMapNode]) -> [ReaderMapLink] {
        var solids: [ReaderMapLink] = []
        var lights: [ReaderMapLink] = []

        for node in nodes where selected.contains(node.id) && qualifies(node) {
            solids.append(contentsOf: outgoing(from: node, among: nodes))
            lights.append(contentsOf: incoming(to: node, among: nodes))
        }

        var solidPairs = Set<UnorderedPair>()
        var seen = Set<DirectedPair>()
        var result: [ReaderMapLink] = []
        for link in solids where seen.insert(DirectedPair(link.from, link.to)).inserted {
            solidPairs.insert(UnorderedPair(link.from, link.to))
            result.append(link)
        }
        var seenLight = Set<DirectedPair>()
        for link in lights {
            guard !solidPairs.contains(UnorderedPair(link.from, link.to)),
                  seenLight.insert(DirectedPair(link.from, link.to)).inserted else { continue }
            result.append(link)
        }
        return result
    }

    /// Every solid link on the map (for "connected" queries): the outgoing
    /// links of every node, as though each were selected in turn.
    static func allMentions(among nodes: [ReaderMapNode]) -> [ReaderMapLink] {
        var seen = Set<DirectedPair>()
        var result: [ReaderMapLink] = []
        for node in nodes where qualifies(node) {
            for link in outgoing(from: node, among: nodes)
            where seen.insert(DirectedPair(link.from, link.to)).inserted {
                result.append(link)
            }
        }
        return result
    }

    // MARK: Author's rules

    /// updateGlossaryConnections only looks at a selected node whose
    /// trimmed title or definition is non-empty.
    private static func qualifies(_ node: ReaderMapNode) -> Bool {
        !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !node.definition.isEmpty
    }

    /// `glossaryNodeLinksFrom`: every other node whose definition or name
    /// appears as a whole word in the selected node's definition, with
    /// the sentences it appears in. Failing that, a node whose name or
    /// definition equals one of the selected node's comma-separated name
    /// components (case-insensitive) is linked with no sentences.
    ///
    /// Author also searched for each node's citation fields and its year —
    /// and, for a node without a citation, the year came out as "-1", so a
    /// definition with " -1" in it linked to every node on the map. We have
    /// no citations, and the "-1" is a bug, so neither is searched for.
    private static func outgoing(from node: ReaderMapNode, among nodes: [ReaderMapNode]) -> [ReaderMapLink] {
        let entryText = node.definition
        let components = node.name.components(separatedBy: ",")
        var links: [ReaderMapLink] = []

        for other in nodes where other.id != node.id {
            let terms = [other.definition, other.name].filter { !$0.isEmpty }
            let found = terms.flatMap { sentences(in: entryText, containing: $0) }
            if !found.isEmpty {
                links.append(ReaderMapLink(from: node.id, to: other.id, solid: true, sentences: uniqued(found)))
            } else {
                for component in components {
                    let lowered = component.lowercased()
                    if lowered == other.name.lowercased() || lowered == other.definition.lowercased() {
                        links.append(ReaderMapLink(from: node.id, to: other.id, solid: true, sentences: []))
                        break
                    }
                }
            }
        }
        return links
    }

    /// `glossaryNodeLinksTo`: every entry — smallest phrase first — whose
    /// definition contains the selected node's name as a plain,
    /// case-insensitive substring ("art" is found in "start"; that is
    /// Author's rule and why these lines are drawn light). The entry is
    /// turned back into a node by name (`node(with:)`), so the first node
    /// carrying that name wins.
    private static func incoming(to node: ReaderMapNode, among nodes: [ReaderMapNode]) -> [ReaderMapLink] {
        let sentence = node.name.lowercased()
        guard !sentence.isEmpty else { return [] }

        let entries = nodes.enumerated().sorted {
            $0.element.name.count != $1.element.name.count
                ? $0.element.name.count < $1.element.name.count
                : $0.offset < $1.offset
        }.map(\.element)

        var links: [ReaderMapLink] = []
        for entry in entries where entry.definition.lowercased().contains(sentence) {
            let phrase = entry.name.lowercased()
            guard let matching = nodes.first(where: { $0.name.lowercased() == phrase }),
                  matching.id != node.id else { continue }
            links.append(ReaderMapLink(from: matching.id, to: node.id, solid: false, sentences: []))
        }
        return links
    }

    // MARK: String helpers (Author's String extensions)

    /// `String.sentencesContaining` (CanvasViewController.swift): each
    /// trimmed sentence of `text` in which `term` occurs as a whole word,
    /// case-insensitively — once per occurrence, as Author returns it.
    /// A word boundary is any character outside `.alphanumerics`, and the
    /// start or end of the sentence.
    ///
    /// Author compared the match's end against the sentence's Character
    /// count while every other offset is UTF-16; here the end is compared
    /// against the UTF-16 length, as intended. They differ only in
    /// sentences carrying emoji or composed characters.
    static func sentences(in text: String, containing term: String) -> [String] {
        guard !term.isEmpty, !text.isEmpty else { return [] }
        var result: [String] = []
        let loweredTerm = term.lowercased()

        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            guard let sentenceString = substring else { return }
            let trimmed = sentenceString.trimmingCharacters(in: .whitespacesAndNewlines)
            let sentence = trimmed as NSString
            guard sentence.range(of: term, options: .caseInsensitive).location != NSNotFound else { return }

            let length = sentence.length
            for range in nsRanges(of: loweredTerm, in: trimmed.lowercased()) {
                var isAMatch = true
                if range.location > 0, !doesWordBegin(trimmed, before: range.location) {
                    isAMatch = false
                }
                if NSMaxRange(range) < length, !doesWordFinish(trimmed, at: NSMaxRange(range)) {
                    isAMatch = false
                }
                if isAMatch {
                    result.append(trimmed)
                }
            }
        }
        return result
    }

    /// `String.nsRanges(of:)` (LiquidAuthorTextCore/StringExtensions.swift):
    /// every non-overlapping case-insensitive occurrence.
    private static func nsRanges(of searchString: String, in string: String) -> [NSRange] {
        let selfString = string as NSString
        var searchRange = NSRange(location: 0, length: selfString.length)
        var ranges: [NSRange] = []
        while searchRange.location < selfString.length {
            searchRange.length = selfString.length - searchRange.location
            let found = selfString.range(of: searchString, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            searchRange.location = found.location + found.length
            ranges.append(found)
        }
        return ranges
    }

    /// `String.doesWordFinish(at:)`: the character at `index` is not
    /// alphanumeric (false past the end, as in Author).
    private static func doesWordFinish(_ string: String, at index: Int) -> Bool {
        let ns = string as NSString
        guard index <= ns.length - 1 else { return false }
        let after = CharacterSet(charactersIn: ns.substring(with: NSMakeRange(index, 1)))
        return !after.isSubset(of: .alphanumerics)
    }

    /// `String.doesWordBegin(before:)`: the character before `index` is
    /// not alphanumeric (false at the start, as in Author).
    private static func doesWordBegin(_ string: String, before index: Int) -> Bool {
        guard index > 0 else { return false }
        let ns = string as NSString
        let before = CharacterSet(charactersIn: ns.substring(with: NSMakeRange(index - 1, 1)))
        return !before.isSubset(of: .alphanumerics)
    }

    private static func uniqued(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }

    private struct DirectedPair: Hashable {
        let a: String, b: String
        init(_ a: String, _ b: String) { self.a = a; self.b = b }
    }

    private struct UnorderedPair: Hashable {
        let a: String, b: String
        init(_ x: String, _ y: String) {
            if x < y { a = x; b = y } else { a = y; b = x }
        }
    }
}

// MARK: - Analysis views

/// Author's Layout ▸ Analysis Views (`AnalysisView`, FlowDocument.swift).
/// Timeline and Neighborhoods are here because they degrade the way
/// Author's do: without dates every node is "undated" and Timeline is an
/// alphabetical block; without categories every node is a concept and
/// Neighborhoods is one block led by the best-connected. Supply dates and
/// categories through the longer `analysis` overload when they exist.
nonisolated enum ReaderMapAnalysis: String, CaseIterable, Identifiable, Sendable {
    case magneticCenter, islands, spine, orbits, timeline, neighborhoods

    var id: String { rawValue }

    /// Author's menu titles, in Author's menu order.
    var title: String {
        switch self {
        case .magneticCenter: return "Magnetic Center"
        case .islands: return "Islands"
        case .spine: return "Spine"
        case .orbits: return "Orbits"
        case .timeline: return "Timeline"
        case .neighborhoods: return "Neighborhoods"
        }
    }
}

nonisolated enum ReaderMapLayouts {

    // MARK: Constants (Author's exact values)

    /// AnalysisView's node-card metrics: the horizontal pitch fits a card
    /// plus breathing room, the vertical pitch a card row.
    static let xPitch: CGFloat = 170
    static let yPitch: CGFloat = 70
    static let clusterPadding: CGFloat = 40

    /// CanvasView+Alignment: the gap Distribute packs nodes with.
    static let distributeSpacing: CGFloat = 20
    /// CanvasView+Alignment: Gather's step and breathing room.
    static let gatherFraction: CGFloat = 0.2
    static let gatherGap: CGFloat = 12
    /// CanvasView.toggleZoom: Z's padding and floor.
    static let zoomPadding: CGFloat = 40
    static let minimumMagnification: CGFloat = 0.25

    /// The key under which Spine returns the label position of
    /// `sections[index]`.
    static func sectionKey(_ index: Int) -> String { "section:\(index)" }

    // MARK: Analysis

    /// Positions are node CENTRES relative to the canvas centre, y
    /// pointing DOWN (Author's canvas convention).
    /// `sections`: the document's headings in order with the plain text
    /// under each (for Spine).
    ///
    /// Spine: in Author the sections are Section-tagged nodes on the map;
    /// here they come in as (title, text). They are laid out as Author
    /// lays out its Section nodes — the spine column at x 0, in document
    /// order — and their label positions are returned keyed
    /// `"section:<index>"` (see `sectionKey`) alongside the concept
    /// positions, so the view can draw them. No other view returns
    /// section keys.
    static func analysis(_ kind: ReaderMapAnalysis, nodes: [ReaderMapNode],
                         sections: [(title: String, text: String)]) -> [String: CGPoint] {
        analysis(kind, nodes: nodes, sections: sections, dates: [:], categories: [:])
    }

    /// The same, with the optional inputs Timeline and Neighborhoods use
    /// when they exist: a creation date per node id, and a category per
    /// node id ("section", "concept", "citation", "note" or a user
    /// category; missing means "concept", as in Author).
    static func analysis(_ kind: ReaderMapAnalysis, nodes: [ReaderMapNode],
                         sections: [(title: String, text: String)],
                         dates: [String: Date], categories: [String: String]) -> [String: CGPoint] {
        switch kind {
        case .magneticCenter: return magneticPositions(nodes)
        case .islands: return islandPositions(nodes)
        case .spine: return spinePositions(nodes, sections: sections)
        case .orbits: return orbitPositions(nodes)
        case .timeline: return timelinePositions(nodes, dates: dates, categories: categories)
        case .neighborhoods: return neighborhoodPositions(nodes, categories: categories)
        }
    }

    // MARK: Shared analysis machinery

    private static func byName(_ a: ReaderMapNode, _ b: ReaderMapNode) -> Bool {
        a.name.localizedCompare(b.name) == .orderedAscending
    }

    /// The terms a node is found by: its comma-separated name components,
    /// trimmed and lowercased, longer than one character (AnalysisView's
    /// `referenceLinks`).
    private static func terms(of node: ReaderMapNode) -> [String] {
        node.name.components(separatedBy: ",").compactMap { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return trimmed.count > 1 ? trimmed : nil
        }
    }

    /// AnalysisView's `referenceLinks`: a node points at every other node
    /// whose term appears (plain substring, case-insensitive) in its
    /// definition. What every analysis view scores and clusters by.
    static func referenceLinks(among nodes: [ReaderMapNode]) -> [String: Set<String>] {
        let termed = nodes.map { ($0, terms(of: $0)) }
        var links: [String: Set<String>] = [:]
        for node in nodes {
            let definition = node.definition.lowercased()
            guard !definition.isEmpty else { continue }
            var found = Set<String>()
            for (other, otherTerms) in termed where other.id != node.id {
                if otherTerms.contains(where: { definition.contains($0) }) {
                    found.insert(other.id)
                }
            }
            if !found.isEmpty { links[node.id] = found }
        }
        return links
    }

    /// AnalysisView's `recentered`: shifts a layout so its centroid sits
    /// at the origin.
    private static func recentered(_ positions: [String: CGPoint]) -> [String: CGPoint] {
        guard !positions.isEmpty else { return positions }
        let count = CGFloat(positions.count)
        let midX = positions.values.reduce(CGFloat(0)) { $0 + $1.x } / count
        let midY = positions.values.reduce(CGFloat(0)) { $0 + $1.y } / count
        return positions.mapValues { CGPoint(x: $0.x - midX, y: $0.y - midY) }
    }

    /// AnalysisView's `placeBlock`: a reading-order block (rows filling
    /// left to right) whose origin is the top-left cell.
    @discardableResult
    private static func placeBlock(_ nodes: [ReaderMapNode], at origin: CGPoint, columns: Int,
                                   into positions: inout [String: CGPoint]) -> CGSize {
        guard !nodes.isEmpty else { return .zero }
        let columnCount = max(1, columns)
        for (index, node) in nodes.enumerated() {
            positions[node.id] = CGPoint(x: origin.x + CGFloat(index % columnCount) * xPitch,
                                         y: origin.y + CGFloat(index / columnCount) * yPitch)
        }
        let rows = (nodes.count + columnCount - 1) / columnCount
        return CGSize(width: CGFloat(min(nodes.count, columnCount)) * xPitch, height: CGFloat(rows) * yPitch)
    }

    private static func nodeMap(_ nodes: [ReaderMapNode]) -> [String: ReaderMapNode] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Magnetic Center

    /// AnalysisView `magneticPositions`: a node's score is how many other
    /// nodes' terms appear in its definition. The highest scores sit at
    /// the centre, descending score buckets form rings outward (170
    /// apart, at least 160 of arc per node), zero scores in the outermost
    /// band. A lone top scorer sits exactly at the centre. Not recentred,
    /// as in Author.
    private static func magneticPositions(_ nodes: [ReaderMapNode]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let links = referenceLinks(among: nodes)
        var scores: [String: Int] = [:]
        for node in nodes { scores[node.id] = links[node.id]?.count ?? 0 }

        let distinctScores = Set(scores.values).sorted(by: >)
        var ringIndexByScore: [Int: Int] = [:]
        for (index, score) in distinctScores.enumerated() { ringIndexByScore[score] = index }

        var nodesByRing: [Int: [ReaderMapNode]] = [:]
        for node in nodes {
            nodesByRing[ringIndexByScore[scores[node.id] ?? 0] ?? 0, default: []].append(node)
        }

        let ringSpacing: CGFloat = 170
        let arcPerNode: CGFloat = 160
        var positions: [String: CGPoint] = [:]
        var radius: CGFloat = 0

        for ring in 0..<distinctScores.count {
            let ringNodes = (nodesByRing[ring] ?? []).sorted(by: byName)
            guard !ringNodes.isEmpty else { continue }
            if ring == 0 && ringNodes.count == 1 {
                positions[ringNodes[0].id] = .zero
                continue
            }
            let neededRadius = CGFloat(ringNodes.count) * arcPerNode / (2 * .pi)
            radius = max(radius + ringSpacing, neededRadius)
            for (index, node) in ringNodes.enumerated() {
                let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(ringNodes.count)
                positions[node.id] = CGPoint(x: radius * cos(angle), y: radius * sin(angle))
            }
        }
        return positions
    }

    // MARK: Islands

    /// AnalysisView `islandPositions`: connected clusters (references
    /// treated undirected), biggest first, each laid out as its own small
    /// Magnetic Center on a square-ish grid; unconnected nodes gather in
    /// an orphan band beneath.
    private static func islandPositions(_ nodes: [ReaderMapNode]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let links = referenceLinks(among: nodes)
        var adjacency: [String: Set<String>] = [:]
        for (source, targets) in links {
            for target in targets {
                adjacency[source, default: []].insert(target)
                adjacency[target, default: []].insert(source)
            }
        }

        let byID = nodeMap(nodes)
        var visited = Set<String>()
        var islands: [[ReaderMapNode]] = []
        var orphans: [ReaderMapNode] = []

        for node in nodes.sorted(by: byName) {
            guard !visited.contains(node.id) else { continue }
            visited.insert(node.id)
            guard let neighbors = adjacency[node.id], !neighbors.isEmpty else {
                orphans.append(node)
                continue
            }
            var island: [ReaderMapNode] = []
            var stack = [node.id]
            while let id = stack.popLast() {
                if let member = byID[id] { island.append(member) }
                for next in (adjacency[id] ?? []).sorted() where !visited.contains(next) {
                    visited.insert(next)
                    stack.append(next)
                }
            }
            islands.append(island)
        }

        islands.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            return byName($0[0], $1[0])
        }

        var layouts: [[String: CGPoint]] = []
        var radii: [CGFloat] = []
        for island in islands {
            let layout = magneticPositions(island)
            let radius = layout.values.map { sqrt($0.x * $0.x + $0.y * $0.y) }.max() ?? 0
            layouts.append(layout)
            radii.append(max(radius + xPitch / 2, 90))
        }

        var positions: [String: CGPoint] = [:]
        let columns = max(1, Int(ceil(Double(islands.count).squareRoot())))
        var rowStart = 0
        var y: CGFloat = 0
        while rowStart < islands.count {
            let rowEnd = min(rowStart + columns, islands.count)
            let rowRadius = radii[rowStart..<rowEnd].max() ?? 0
            var x: CGFloat = 0
            for i in rowStart..<rowEnd {
                x += radii[i]
                for (id, p) in layouts[i] {
                    positions[id] = CGPoint(x: p.x + x, y: p.y + y + rowRadius)
                }
                x += radii[i] + clusterPadding
            }
            y += 2 * rowRadius + clusterPadding
            rowStart = rowEnd
        }

        if !orphans.isEmpty {
            placeBlock(orphans, at: CGPoint(x: 0, y: y), columns: max(columns * 2, 6), into: &positions)
        }
        return recentered(positions)
    }

    // MARK: Spine

    /// AnalysisView `spinePositions`: the sections form a vertical spine in
    /// document order, each with the concepts its text mentions fanned out
    /// to its right (up to three rows, 200 out from the spine); a concept
    /// belongs to the first section that mentions it. Concepts no section
    /// mentions form a block on the left. Without sections this falls
    /// back to Magnetic Center, as Author's does.
    ///
    /// "Mentions" is referenceLinks' rule: one of the concept's terms is a
    /// plain substring of the section's text. Section label positions are
    /// returned under `sectionKey(index)`; they take part in the
    /// recentring, as Author's Section nodes do.
    private static func spinePositions(_ nodes: [ReaderMapNode],
                                       sections: [(title: String, text: String)]) -> [String: CGPoint] {
        guard !nodes.isEmpty || !sections.isEmpty else { return [:] }
        guard !sections.isEmpty else { return magneticPositions(nodes) }

        let termed = nodes.map { ($0, terms(of: $0)) }
        var fans: [[ReaderMapNode]] = []
        var claimed = Set<String>()
        for section in sections {
            let text = section.text.lowercased()
            var members: [ReaderMapNode] = []
            if !text.isEmpty {
                members = termed
                    .filter { !claimed.contains($0.0.id) && $0.1.contains(where: { text.contains($0) }) }
                    .map(\.0)
                    .sorted(by: byName)
            }
            for member in members { claimed.insert(member.id) }
            fans.append(members)
        }

        let unmentioned = nodes.filter { !claimed.contains($0.id) }.sorted(by: byName)

        let fanRows = 3
        var positions: [String: CGPoint] = [:]
        var y: CGFloat = 0
        for (sectionIndex, members) in fans.enumerated() {
            let rows = min(max(members.count, 1), fanRows)
            let blockHeight = CGFloat(rows) * yPitch
            let centerY = y + blockHeight / 2
            positions[sectionKey(sectionIndex)] = CGPoint(x: 0, y: centerY)

            for (index, member) in members.enumerated() {
                let column = index / fanRows
                let row = index % fanRows
                let rowsInColumn = min(fanRows, members.count - column * fanRows)
                positions[member.id] = CGPoint(
                    x: 200 + CGFloat(column) * xPitch,
                    y: centerY + (CGFloat(row) - CGFloat(rowsInColumn - 1) / 2) * yPitch)
            }
            y += blockHeight + yPitch
        }

        if !unmentioned.isEmpty {
            let columnHeight = max(Int(ceil(Double(unmentioned.count).squareRoot())), 4)
            let columns = (unmentioned.count + columnHeight - 1) / columnHeight
            placeBlock(unmentioned, at: CGPoint(x: -CGFloat(columns) * xPitch - 200, y: 0),
                       columns: columns, into: &positions)
        }
        return recentered(positions)
    }

    // MARK: Orbits

    /// AnalysisView `orbitPositions`: every node referenced by at least two
    /// others is a hub with its referencers circling it at 0.85 of its
    /// radius; each node orbits the strongest hub it references. Systems
    /// sit on a square-ish grid, free nodes in a band beneath; with no
    /// hubs this falls back to Magnetic Center.
    private static func orbitPositions(_ nodes: [ReaderMapNode]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let links = referenceLinks(among: nodes)
        var referencedBy: [String: Set<String>] = [:]
        for (source, targets) in links {
            for target in targets { referencedBy[target, default: []].insert(source) }
        }

        let byID = nodeMap(nodes)
        var hubs = nodes.filter { (referencedBy[$0.id]?.count ?? 0) >= 2 }
        guard !hubs.isEmpty else { return magneticPositions(nodes) }

        hubs.sort {
            let a = referencedBy[$0.id]?.count ?? 0
            let b = referencedBy[$1.id]?.count ?? 0
            if a != b { return a > b }
            return byName($0, $1)
        }

        let hubIDs = Set(hubs.map(\.id))
        var systems: [String: [ReaderMapNode]] = [:]
        var claimed = Set<String>()
        for hub in hubs {
            let members = (referencedBy[hub.id] ?? [])
                .compactMap { byID[$0] }
                .filter { !hubIDs.contains($0.id) && !claimed.contains($0.id) }
                .sorted(by: byName)
            for member in members { claimed.insert(member.id) }
            systems[hub.id] = members
        }

        let radii: [CGFloat] = hubs.map { hub in
            let count = systems[hub.id]?.count ?? 0
            guard count > 0 else { return 90 }
            return max(170, CGFloat(count) * 160 / (2 * CGFloat.pi))
        }

        var positions: [String: CGPoint] = [:]
        let columns = max(1, Int(ceil(Double(hubs.count).squareRoot())))
        var rowStart = 0
        var y: CGFloat = 0
        while rowStart < hubs.count {
            let rowEnd = min(rowStart + columns, hubs.count)
            let rowRadius = radii[rowStart..<rowEnd].max() ?? 0
            var x: CGFloat = 0
            for i in rowStart..<rowEnd {
                x += radii[i]
                let centerY = y + rowRadius
                positions[hubs[i].id] = CGPoint(x: x, y: centerY)
                let members = systems[hubs[i].id] ?? []
                for (index, member) in members.enumerated() {
                    let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(members.count)
                    positions[member.id] = CGPoint(x: x + radii[i] * 0.85 * cos(angle),
                                                   y: centerY + radii[i] * 0.85 * sin(angle))
                }
                x += radii[i] + clusterPadding
            }
            y += 2 * rowRadius + clusterPadding
            rowStart = rowEnd
        }

        let free = nodes.filter { !hubIDs.contains($0.id) && !claimed.contains($0.id) }.sorted(by: byName)
        if !free.isEmpty {
            placeBlock(free, at: CGPoint(x: 0, y: y), columns: max(columns * 2, 6), into: &positions)
        }
        return recentered(positions)
    }

    // MARK: Timeline

    private static let categoryOrder = ["section": 0, "concept": 1, "citation": 2, "note": 3]

    /// AnalysisView `timelinePositions`: columns by creation date — day,
    /// week or month buckets depending on the span (≤45 days, ≤320 days,
    /// longer) — oldest on the left; within a column sections, concepts,
    /// citations, notes, each alphabetical. Undated nodes form a final
    /// column one pitch further right. With no dates at all: one
    /// alphabetical block, √n columns wide.
    private static func timelinePositions(_ nodes: [ReaderMapNode], dates: [String: Date],
                                          categories: [String: String]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        var dated: [(node: ReaderMapNode, date: Date)] = []
        var undated: [ReaderMapNode] = []
        for node in nodes {
            if let date = dates[node.id] { dated.append((node, date)) } else { undated.append(node) }
        }

        guard !dated.isEmpty else {
            var positions: [String: CGPoint] = [:]
            let columns = max(1, Int(ceil(Double(undated.count).squareRoot())))
            placeBlock(undated.sorted(by: byName), at: .zero, columns: columns, into: &positions)
            return recentered(positions)
        }

        let calendar = Calendar(identifier: .gregorian)
        let allDates = dated.map(\.date)
        let span = (allDates.max() ?? Date()).timeIntervalSince(allDates.min() ?? Date())
        let day: TimeInterval = 24 * 60 * 60

        let bucketStart: (Date) -> Date
        if span <= 45 * day {
            bucketStart = { calendar.startOfDay(for: $0) }
        } else if span <= 320 * day {
            bucketStart = { calendar.dateInterval(of: .weekOfYear, for: $0)?.start ?? calendar.startOfDay(for: $0) }
        } else {
            bucketStart = { calendar.dateInterval(of: .month, for: $0)?.start ?? calendar.startOfDay(for: $0) }
        }

        var buckets: [Date: [ReaderMapNode]] = [:]
        for (node, date) in dated { buckets[bucketStart(date), default: []].append(node) }

        func columnSort(_ a: ReaderMapNode, _ b: ReaderMapNode) -> Bool {
            let ca = categoryOrder[categories[a.id] ?? "concept"] ?? 4
            let cb = categoryOrder[categories[b.id] ?? "concept"] ?? 4
            if ca != cb { return ca < cb }
            return byName(a, b)
        }

        var positions: [String: CGPoint] = [:]
        var x: CGFloat = 0
        func place(column: [ReaderMapNode]) {
            for (index, node) in column.enumerated() {
                positions[node.id] = CGPoint(x: x, y: (CGFloat(index) - CGFloat(column.count - 1) / 2) * yPitch)
            }
            x += xPitch
        }
        for key in buckets.keys.sorted() {
            place(column: (buckets[key] ?? []).sorted(by: columnSort))
        }
        if !undated.isEmpty {
            x += xPitch
            place(column: undated.sorted(by: byName))
        }
        return recentered(positions)
    }

    // MARK: Neighborhoods

    /// AnalysisView `neighborhoodPositions`: one block per category —
    /// sections, concepts, citations, notes, then user categories
    /// alphabetically — side by side 40 apart, each ordered by magnetic
    /// score so the best-connected lead their block.
    private static func neighborhoodPositions(_ nodes: [ReaderMapNode],
                                              categories: [String: String]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let links = referenceLinks(among: nodes)

        var groups: [String: [ReaderMapNode]] = [:]
        for node in nodes { groups[categories[node.id] ?? "concept", default: []].append(node) }

        let preferred = ["section", "concept", "citation", "note"]
        var order = preferred.filter { groups[$0] != nil }
        order += groups.keys.filter { !preferred.contains($0) }.sorted()

        func groupSort(_ a: ReaderMapNode, _ b: ReaderMapNode) -> Bool {
            let sa = links[a.id]?.count ?? 0
            let sb = links[b.id]?.count ?? 0
            if sa != sb { return sa > sb }
            return byName(a, b)
        }

        var positions: [String: CGPoint] = [:]
        var x: CGFloat = 0
        for category in order {
            let members = (groups[category] ?? []).sorted(by: groupSort)
            let columns = max(1, Int(ceil(Double(members.count).squareRoot())))
            let size = placeBlock(members, at: CGPoint(x: x, y: 0), columns: columns, into: &positions)
            x += size.width + clusterPadding
        }
        return recentered(positions)
    }

    // MARK: - Gather

    /// Gather (G) — `CanvasView.gather`: each call moves the nodes a fifth
    /// of the way toward the average of their centres, nearest the middle
    /// first, keeping 12pt of breathing room around each node's own size.
    /// A node whose landing spot would overlap one already placed stays
    /// put this time; another press tries again.
    ///
    /// As in Author, a real selection (more than one of `ids` on the map)
    /// is gathered on its own; otherwise every node in `positions` is.
    /// Returns `positions` with the moved centres replaced.
    static func gather(_ positions: [String: CGPoint], ids: Set<String>, sizes: [String: CGSize]) -> [String: CGPoint] {
        let chosen = ids.filter { positions[$0] != nil }
        let targets = chosen.count > 1 ? chosen : Set(positions.keys)
        let centers = targets.compactMap { id in positions[id].map { (id: id, center: $0) } }
        guard centers.count > 1 else { return positions }

        let count = CGFloat(centers.count)
        let middle = CGPoint(x: centers.reduce(0) { $0 + $1.center.x } / count,
                             y: centers.reduce(0) { $0 + $1.center.y } / count)

        let ordered = centers.sorted {
            let da = hypot($0.center.x - middle.x, $0.center.y - middle.y)
            let db = hypot($1.center.x - middle.x, $1.center.y - middle.y)
            return da != db ? da < db : $0.id < $1.id
        }

        var result = positions
        var placed: [CGRect] = []
        for (id, center) in ordered {
            let candidate = CGPoint(x: center.x + (middle.x - center.x) * gatherFraction,
                                    y: center.y + (middle.y - center.y) * gatherFraction)
            let size = sizes[id] ?? .zero
            func frame(at point: CGPoint) -> CGRect {
                CGRect(x: point.x - (size.width + gatherGap) / 2,
                       y: point.y - (size.height + gatherGap) / 2,
                       width: size.width + gatherGap,
                       height: size.height + gatherGap)
            }
            let resting = placed.contains(where: { $0.intersects(frame(at: candidate)) }) ? center : candidate
            placed.append(frame(at: resting))
            result[id] = resting
        }
        return result
    }

    // MARK: - Align

    enum Alignment { case left, center, right }

    /// Align ▸ Left / Center / Right — `CanvasView.leftAlign`,
    /// `horizontalCenterAlign`, `rightAlign`. Left and Right line up the
    /// nodes' edges with the outermost edge among them; Center puts every
    /// centre on the average centre x. Only x changes.
    static func align(_ positions: [String: CGPoint], ids: Set<String>, sizes: [String: CGSize],
                      to alignment: Alignment) -> [String: CGPoint] {
        let targets = ids.filter { positions[$0] != nil }
        guard !targets.isEmpty else { return positions }
        var result = positions
        func width(_ id: String) -> CGFloat { sizes[id]?.width ?? 0 }

        switch alignment {
        case .left:
            let leastLeft = targets.map { positions[$0]!.x - width($0) / 2 }.min() ?? 0
            for id in targets { result[id]!.x = leastLeft + width(id) / 2 }
        case .right:
            let greatestRight = targets.map { positions[$0]!.x + width($0) / 2 }.max() ?? 0
            for id in targets { result[id]!.x = greatestRight - width(id) / 2 }
        case .center:
            let average = targets.reduce(CGFloat(0)) { $0 + positions[$1]!.x } / CGFloat(targets.count)
            for id in targets { result[id]!.x = average }
        }
        return result
    }

    // MARK: - Distribute and Sort

    enum Axis { case horizontal, vertical }

    /// Distribute (V / H), in Author's default "Evenly" style —
    /// `evenHorizontalDistribution` / `evenVerticalDistribution`, ordered
    /// by position.
    ///
    /// Horizontal (two or more nodes): the leftmost stays put and the rest
    /// pack to its right in order, 20pt apart, on its row. Author then
    /// shifted all but the first by a quarter of the first node's width (a
    /// "centring" step whose arithmetic reduces to exactly that), leaving
    /// the first gap wider than the rest; here every gap is 20pt, as the
    /// code's comments intend.
    ///
    /// Vertical (three or more nodes): the topmost and bottommost centres
    /// stay, and the others' centres are spaced evenly between them; x
    /// does not change.
    ///
    /// Author's menu item "Horizontal" (h) was wired to
    /// verticalCenterAlign; the intended action, Distribute Horizontally,
    /// is what is implemented.
    static func distribute(_ positions: [String: CGPoint], ids: Set<String>, sizes: [String: CGSize],
                           along axis: Axis) -> [String: CGPoint] {
        let targets = ids.filter { positions[$0] != nil }
        let ordered: [String]
        switch axis {
        case .horizontal:
            ordered = targets.sorted { positions[$0]!.x != positions[$1]!.x ? positions[$0]!.x < positions[$1]!.x : $0 < $1 }
        case .vertical:
            ordered = targets.sorted { positions[$0]!.y != positions[$1]!.y ? positions[$0]!.y < positions[$1]!.y : $0 < $1 }
        }
        return distribute(positions, ordered: ordered, sizes: sizes, along: axis)
    }

    /// Sort Vertical / Sort Horizontal (+ Reverse) — Author's
    /// `distribute…Alphabetic` / `distribute…Reverse`: the same Evenly
    /// distribution, but in order of name (plain string comparison, as
    /// Author's `<` / `>`) instead of position. Horizontally the
    /// alphabetically first node stays put and the rest pack to its right;
    /// vertically the names take the evenly spaced slots top to bottom.
    static func sort(_ positions: [String: CGPoint], ids: Set<String>, names: [String: String],
                     sizes: [String: CGSize], along axis: Axis, reverse: Bool) -> [String: CGPoint] {
        let targets = ids.filter { positions[$0] != nil }
        let ordered = targets.sorted {
            let a = names[$0] ?? "", b = names[$1] ?? ""
            if a == b { return $0 < $1 }
            return reverse ? a > b : a < b
        }
        return distribute(positions, ordered: ordered, sizes: sizes, along: axis)
    }

    private static func distribute(_ positions: [String: CGPoint], ordered: [String],
                                   sizes: [String: CGSize], along axis: Axis) -> [String: CGPoint] {
        var result = positions
        switch axis {
        case .horizontal:
            guard ordered.count >= 2, let first = ordered.first, let firstCenter = positions[first] else { return positions }
            var currentX = firstCenter.x + (sizes[first]?.width ?? 0) / 2 + distributeSpacing
            for id in ordered.dropFirst() {
                let width = sizes[id]?.width ?? 0
                result[id] = CGPoint(x: currentX + width / 2, y: firstCenter.y)
                currentX += width + distributeSpacing
            }
        case .vertical:
            guard ordered.count > 2 else { return positions }
            let ys = ordered.compactMap { positions[$0]?.y }
            let top = ys.min() ?? 0
            let bottom = ys.max() ?? 0
            let offset = (bottom - top) / CGFloat(ordered.count - 1)
            var accumulator = top
            for id in ordered {
                result[id]!.y = accumulator
                accumulator += offset
            }
        }
        return result
    }

    // MARK: - Zoom to fit

    /// Z's zoom-to-fit scale — `CanvasView.toggleZoom`: fits the given
    /// rects (canvas coords) in a viewport with 40pt padding, never above
    /// 1.0 (Z never zooms in), never below 0.25 (a Map too sprawling to fit
    /// is shown at the floor and scrolled). Returns 1 when there is
    /// nothing to fit, or when it already fits (Author's 0.999 threshold).
    static func fitScale(for rects: [CGRect], in viewport: CGSize) -> CGFloat {
        let occupied = rects.reduce(CGRect.null) { $0.union($1) }
        guard !occupied.isNull, occupied.width > 0, occupied.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        let padded = occupied.insetBy(dx: -zoomPadding, dy: -zoomPadding)
        let fit = min(viewport.width / padded.width, viewport.height / padded.height)
        let scale = min(1.0, max(minimumMagnification, fit))
        return scale < 0.999 ? scale : 1
    }
}
