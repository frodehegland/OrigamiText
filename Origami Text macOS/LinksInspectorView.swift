import SwiftUI

/// Trailing inspector (⌥⌘L): outgoing links and backlinks for the current document.
struct LinksInspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let doc = model.current?.doc {
                LinksList(doc: doc)
            } else {
                ContentUnavailableView("No Document", systemImage: "link")
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 270)
    }
}

private struct LinksList: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        List {
            Section("Links from This Document") {
                if doc.links.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(doc.links.enumerated()), id: \.offset) { _, link in
                    OutgoingLinkRow(link: link, sourceDoc: doc)
                }
            }
            Section("Backlinks") {
                let refs = model.index.backlinks[doc.id] ?? []
                if refs.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
                    BacklinkRow(ref: ref)
                }
            }
        }
    }
}

private struct OutgoingLinkRow: View {
    @Environment(AppModel.self) private var model
    let link: LiquidDoc.Link
    let sourceDoc: LiquidDoc
    @State private var showUnresolvedPopover = false

    var body: some View {
        let resolved = model.resolve(target: link.to, rel: link.rel)
        Button {
            if resolved == nil {
                showUnresolvedPopover = true
            }
            model.follow(link, from: sourceDoc)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let resolved {
                    Text(resolved.doc.title)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 5) {
                        Text(link.to)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("unresolved")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                detailLine
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showUnresolvedPopover) {
            Text("This document is not in the community folder yet.")
                .padding(12)
        }
    }

    @ViewBuilder private var detailLine: some View {
        HStack(spacing: 6) {
            if let rel = link.rel {
                Text(rel)
            }
            if let fragment = link.fragment {
                Text("→ ¶\(fragment)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct BacklinkRow: View {
    @Environment(AppModel.self) private var model
    let ref: BacklinkRef

    var body: some View {
        if let entry = model.index.byID[ref.fromID] {
            Button {
                model.open(entry.doc)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.doc.title)
                        .lineLimit(2)
                    if let rel = ref.rel {
                        Text(rel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
