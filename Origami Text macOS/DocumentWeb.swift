import Foundation

/// An ego-centered neighborhood of the document web: the center document,
/// its direct connections (ring 1), and their connections (ring 2), with
/// every typed link among them. Deterministic and capped, so the picture
/// is stable and legible rather than a physics hairball.
nonisolated struct DocumentWeb: Sendable {

    struct Node: Identifiable, Sendable {
        let entry: IndexEntry
        let ring: Int            // 0 center, 1 direct, 2 second hop
        let parentID: String?    // the ring-1 node a ring-2 node hangs off
        var id: String { entry.id }
    }

    struct Edge: Identifiable, Sendable {
        let fromID: String
        let toID: String
        let rel: String?
        let ordinal: Int
        var id: String { "\(ordinal):\(fromID)>\(toID)" }
    }

    let centerID: String
    var nodes: [Node] = []
    var edges: [Edge] = []
    /// Targets of the center's links that aren't in the library — shown as
    /// dashed ghost stubs.
    var unresolvedTargets: [String] = []
}

nonisolated enum WebBuilder {

    static func web(centeredOn centerID: String,
                    byID: [String: IndexEntry],
                    backlinks: [String: [BacklinkRef]],
                    ringOneLimit: Int = 12,
                    ringTwoLimit: Int = 16) -> DocumentWeb? {
        guard let center = byID[centerID] else { return nil }
        var web = DocumentWeb(centerID: centerID)
        web.nodes.append(DocumentWeb.Node(entry: center, ring: 0, parentID: nil))
        var included: Set<String> = [centerID]

        func neighbors(of id: String) -> [String] {
            guard let entry = byID[id] else { return [] }
            var ids: [String] = []
            for link in entry.doc.links where byID[link.to] != nil { ids.append(link.to) }
            for ref in backlinks[id] ?? [] { ids.append(ref.fromID) }
            var seen: Set<String> = []
            return ids.filter { $0 != id && seen.insert($0).inserted }
        }

        let ringOne = Array(neighbors(of: centerID).prefix(ringOneLimit))
        for id in ringOne {
            guard let entry = byID[id], included.insert(id).inserted else { continue }
            web.nodes.append(DocumentWeb.Node(entry: entry, ring: 1, parentID: centerID))
        }

        var ringTwoCount = 0
        for parent in ringOne {
            guard ringTwoCount < ringTwoLimit else { break }
            for id in neighbors(of: parent) {
                guard ringTwoCount < ringTwoLimit else { break }
                guard let entry = byID[id], included.insert(id).inserted else { continue }
                web.nodes.append(DocumentWeb.Node(entry: entry, ring: 2, parentID: parent))
                ringTwoCount += 1
            }
        }

        // Every typed link among the included documents becomes an edge.
        var ordinal = 0
        for node in web.nodes {
            for link in node.entry.doc.links
            where link.to != node.id && included.contains(link.to) {
                ordinal += 1
                web.edges.append(DocumentWeb.Edge(fromID: node.id, toID: link.to,
                                                  rel: link.rel, ordinal: ordinal))
            }
        }

        web.unresolvedTargets = Array(
            Set(center.doc.links.map(\.to).filter { byID[$0] == nil })
        ).sorted().prefix(4).map { $0 }

        return web
    }
}
