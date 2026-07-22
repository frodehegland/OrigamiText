import SwiftUI

/// The margins of full-screen reading: on the left, the documents this one
/// links to; on the right, the documents that link back to it. Each card is
/// a doorway — click to travel there through the same follow path as the
/// links panel. Both margins claim the same fixed width even when empty,
/// so the reading column stays centered.
struct ReadingConnectionsColumn: View {
    @Environment(AppModel.self) private var model
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
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.title)
                    .font(.callout.weight(.medium))
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

    /// One card per connected document, first mention wins. Outbound cards
    /// keep the link's fragment so travel lands on the cited paragraph;
    /// inbound fragments name a paragraph of this document, so those open
    /// at the top of the citing document instead.
    private var connections: [Connection] {
        var seen: Set<String> = []
        switch direction {
        case .outbound:
            return doc.links.compactMap { link in
                guard link.to != doc.id, !LiquidAddress.isPersonAddress(link.to),
                      seen.insert(link.to).inserted else { return nil }
                let title = model.title(for: link.to)
                return Connection(id: link.to,
                                  title: title ?? link.to,
                                  author: model.index.byID[link.to]?.doc.displayAuthor,
                                  caption: caption(for: link.rel),
                                  fragment: link.fragment,
                                  rel: link.rel,
                                  inLibrary: title != nil)
            }
        case .inbound:
            return (model.index.backlinks[doc.id] ?? []).compactMap { ref in
                guard ref.fromID != doc.id, seen.insert(ref.fromID).inserted,
                      let entry = model.index.byID[ref.fromID] else { return nil }
                return Connection(id: ref.fromID,
                                  title: entry.doc.title,
                                  author: entry.doc.displayAuthor,
                                  caption: caption(for: ref.rel),
                                  fragment: nil,
                                  rel: nil,
                                  inLibrary: true)
            }
        }
    }

    /// "responds-to" reads as "responds to" on the card.
    private func caption(for rel: String?) -> String? {
        rel?.replacingOccurrences(of: "-", with: " ")
    }
}
