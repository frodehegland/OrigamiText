import SwiftUI

extension DocumentRelation {
    /// The discourse colour: connected titles in the reading margins are
    /// tinted by how the documents relate. Nil keeps the default label
    /// colour (cites, summarizes, and relations without a hue yet).
    var titleColor: Color? {
        switch self {
        case .disagreesWith: Color(red: 0.55, green: 0.05, blue: 0.05)   // dark red
        case .extends, .supports: Color(red: 0.0, green: 0.5, blue: 0.1) // green
        case .questions: Color(red: 0.9, green: 0.5, blue: 0.0)          // orange
        case .respondsTo: Color(red: 0.35, green: 0.1, blue: 0.5)        // dark purple
        default: nil
        }
    }
}

/// The margins of full-screen reading: on the left, the documents this one
/// links to; on the right, the documents that link back to it. Each card is
/// a doorway — click to travel there through the same follow path as the
/// links panel. Both margins claim the same fixed width even when empty,
/// so the reading column stays centered.
struct ReadingConnectionsColumn: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.connectionPortraitsKey) private var showPortraits = true
    let doc: LiquidDoc
    let direction: Direction

    enum Direction {
        /// Documents this one links to — the left margin.
        case outbound
        /// Documents that link to this one — the right margin.
        case inbound
    }

    private struct Connection: Identifiable {
        let id: String
        let title: String
        let author: String?
        let caption: String?
        let fragment: String?
        let rel: String?
        let inLibrary: Bool
        /// The relation for the title tint. Kept apart from `rel`, which
        /// feeds `follow` and stays nil on inbound cards.
        let relation: DocumentRelation?
    }

    var body: some View {
        let connections = connections
        VStack(alignment: .leading, spacing: 10) {
            if !connections.isEmpty {
                Text(direction == .outbound ? "Links To" : "Linked From")
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(connections) { connection in
                            card(connection)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func card(_ connection: Connection) -> some View {
        Button {
            model.follow(to: connection.id, fragment: connection.fragment, rel: connection.rel)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if showPortraits, let author = connection.author {
                    PersonAvatarView(name: author, size: 28)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(connection.relation?.titleColor.map(AnyShapeStyle.init)
                                         ?? AnyShapeStyle(.primary))
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    if let author = connection.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let caption = connection.caption {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(connection.inLibrary ? 1 : 0.5)
        .help(connection.inLibrary
              ? "Open “\(connection.title)”"
              : "\(connection.id) is not in the library")
    }

    /// One card per connected document, first mention wins — except the
    /// relation: a responding letter carries a plain citation link AND a
    /// "responds-to" link, and whichever named relation exists is the one
    /// the card wears (tint and caption), not whichever came first.
    private var connections: [Connection] {
        var seen: Set<String> = []
        switch direction {
        case .outbound:
            var namedRel: [String: String] = [:]
            for link in doc.links where namedRel[link.to] == nil {
                if let rel = link.rel { namedRel[link.to] = rel }
            }
            return doc.links.compactMap { link in
                guard link.to != doc.id, !LiquidAddress.isPersonAddress(link.to),
                      seen.insert(link.to).inserted else { return nil }
                let title = model.title(for: link.to)
                let rel = namedRel[link.to]
                return Connection(id: link.to,
                                  title: title ?? link.to,
                                  author: model.document(for: link.to)?.displayAuthor,
                                  caption: caption(for: rel),
                                  fragment: link.fragment,
                                  rel: link.rel,
                                  inLibrary: title != nil,
                                  relation: DocumentRelation.from(rel: rel))
            }
        case .inbound:
            let refs = model.index.backlinks[doc.id] ?? []
            var namedRel: [String: String] = [:]
            for ref in refs where namedRel[ref.fromID] == nil {
                if let rel = ref.rel { namedRel[ref.fromID] = rel }
            }
            return refs.compactMap { ref in
                guard ref.fromID != doc.id, seen.insert(ref.fromID).inserted,
                      let entry = model.index.byID[ref.fromID] else { return nil }
                let rel = namedRel[ref.fromID]
                return Connection(id: ref.fromID,
                                  title: entry.doc.title,
                                  author: entry.doc.displayAuthor,
                                  caption: caption(for: rel),
                                  fragment: nil,
                                  rel: nil,
                                  inLibrary: true,
                                  relation: DocumentRelation.from(rel: rel))
            }
        }
    }

    /// "responds-to" reads as "responds to" on the card.
    private func caption(for rel: String?) -> String? {
        rel?.replacingOccurrences(of: "-", with: " ")
    }
}
