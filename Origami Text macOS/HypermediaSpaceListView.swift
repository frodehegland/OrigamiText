import SwiftUI

/// One document on a space, with the documents filed under it. A space's
/// paths ARE its shape — `pro/3800935.3830872` sits inside `pro`, which
/// is the conference's Proceedings — so a document that holds others
/// reads as a folder, and opens as a document all the same.
private struct HypermediaNode: Identifiable {
    let info: HypermediaDocumentInfo?
    /// The path segment this node stands at, for a folder the space
    /// names only through its children.
    let segment: String
    let path: [String]
    /// Nil for a leaf, so no disclosure triangle appears.
    var children: [HypermediaNode]?
    var id: String { info?.id ?? "path:" + path.joined(separator: "/") }

    var title: String {
        info?.title ?? HypermediaFetcher.humanize(segment)
    }

    /// Everything filed beneath, however deep — what a folder's count
    /// means to a reader.
    var descendantCount: Int {
        (children ?? []).reduce(0) { $0 + 1 + $1.descendantCount }
    }
}

/// Sidebar ▸ Hypermedia ▸ a space: the documents it holds, as the space
/// files them — a document with others under it opens as a folder, and
/// still opens as itself. Click a row and it reads in the reader. The
/// space is the authority — the list is fetched, not kept.
struct HypermediaSpaceListView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.listTitleFontKey) private var listTitleFamily = ""
    let domain: String

    @State private var selectedID: String?
    @State private var searchText = ""

    private var space: HypermediaSpace? { model.hypermedia.space(for: domain) }

    private var documents: [HypermediaDocumentInfo] {
        let all = model.hypermedia.documents(for: domain) ?? []
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.path.joined(separator: "/").localizedCaseInsensitiveContains(needle)
                || $0.breadcrumbs.joined(separator: " ").localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        Group {
            if let space {
                content(for: space)
            } else {
                ContentUnavailableView {
                    Label(domain, systemImage: "globe")
                } description: {
                    Text("This space is no longer followed.")
                }
            }
        }
    }

    /// The space's documents as it files them. A search flattens the
    /// tree: while looking for something, the folder it sits in is less
    /// use than seeing it at all.
    private var tree: [HypermediaNode] {
        let all = documents
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return all.map {
                HypermediaNode(info: $0, segment: $0.path.last ?? "",
                               path: $0.path, children: nil)
            }
        }
        return Self.tree(of: all)
    }

    /// Builds the tree from the paths: each document under the document
    /// (or bare path) that names its parent. A parent the space does not
    /// document itself still stands as a folder, so nothing is orphaned.
    // fileprivate so the shape can be checked directly against a live
    // space, which is the only way to know a tree is right.
    fileprivate static func tree(of documents: [HypermediaDocumentInfo]) -> [HypermediaNode] {
        // Children by parent path, keeping the space's own order.
        var byParent: [String: [HypermediaDocumentInfo]] = [:]
        var documented: Set<String> = []
        for document in documents {
            documented.insert(key(document.path))
            byParent[key(document.path.dropLast()), default: []].append(document)
        }

        func build(_ path: [String], info: HypermediaDocumentInfo?) -> HypermediaNode {
            let children = (byParent[key(path)] ?? []).map { build($0.path, info: $0) }
            return HypermediaNode(info: info, segment: path.last ?? "", path: path,
                                  children: children.isEmpty ? nil : children)
        }

        var roots = (byParent[key([])] ?? []).map { build($0.path, info: $0) }
        // A document whose parent path the space never documents — its
        // folder is implied, and stands for it.
        for (parent, group) in byParent where !parent.isEmpty && !documented.contains(parent) {
            let path = parent.split(separator: "/").map(String.init)
            // Only when its own parent is not documented either, else it
            // has already been reached from above.
            guard !documented.contains(key(path.dropLast())) || path.count == 1 else { continue }
            let children = group.map { build($0.path, info: $0) }
            roots.append(HypermediaNode(info: nil, segment: path.last ?? "",
                                        path: path, children: children))
        }
        return roots
    }

    fileprivate static func key(_ path: some Sequence<String>) -> String {
        path.joined(separator: "/")
    }

    @ViewBuilder private func content(for space: HypermediaSpace) -> some View {
        List(selection: $selectedID) {
            Section {
                ForEach(tree) { node in
                    HypermediaOutlineRow(node: node, space: space,
                                         showsParents: !searchText.isEmpty,
                                         titleFamily: listTitleFamily)
                }
            } header: {
                header(for: space)
            }
        }
        // The list starts right under the toolbar, no dead air.
        .contentMargins(.top, 0, for: .scrollContent)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search \(space.title)")
        .onChange(of: selectedID) { _, id in
            guard let id, let info = documents.first(where: { $0.id == id }) else { return }
            Task { await model.openHypermedia(info, space: space) }
        }
        .task(id: space.domain) {
            await model.hypermedia.loadIfNeeded(space)
        }
        .overlay { stateOverlay(for: space) }
    }

    private func header(for space: HypermediaSpace) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(space.title)
                Text(space.domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
            Spacer()
            Button {
                Task { await model.hypermedia.refresh(space) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Fetch the space's documents again")
        }
    }

    @ViewBuilder private func stateOverlay(for space: HypermediaSpace) -> some View {
        switch model.hypermedia.listings[space.domain] {
        case .none, .loading?:
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Fetching \(space.domain)…")
            }
        case .failed(let message)?:
            ContentUnavailableView {
                Label(space.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await model.hypermedia.refresh(space) }
                }
            }
        case .loaded(let docs)?:
            if docs.isEmpty {
                ContentUnavailableView {
                    Label(space.title, systemImage: "globe")
                } description: {
                    Text("This space has no documents yet.")
                }
            } else if documents.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}

/// One row of a space's outline, and everything under it. A named type
/// because it renders itself: a `some View` function cannot be defined
/// in terms of itself, and a folder's contents are more rows like this.
private struct HypermediaOutlineRow: View {
    let node: HypermediaNode
    let space: HypermediaSpace
    /// A search flattens the tree, so a row then needs its parents named.
    let showsParents: Bool
    let titleFamily: String

    var body: some View { content }

    /// A node and everything under it. A folder discloses its contents
    /// and carries how many; a leaf is a row as before.
    @ViewBuilder private var content: some View {
        if let children = node.children {
            DisclosureGroup {
                ForEach(children) { child in
                    HypermediaOutlineRow(node: child, space: space,
                                         showsParents: showsParents,
                                         titleFamily: titleFamily)
                }
            } label: {
                folderLabel
            }
        } else if let info = node.info {
            row(info)
        }
    }

    /// A folder's own row: its name, its count, and — when the space
    /// documents the folder itself, as a conference documents its
    /// Proceedings — selectable, so it opens like any other document.
    @ViewBuilder private var folderLabel: some View {
        let label = HStack(spacing: 6) {
            Text(node.title)
                .font(titleFamily.isEmpty ? .body : Font.custom(titleFamily, size: 13))
                .lineLimit(2)
            Spacer(minLength: 4)
            Text("\(node.descendantCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        if let info = node.info {
            label
                .tag(info.id)
                .accessibilityLabel("\(node.title), \(node.descendantCount) documents")
                .accessibilityHint("Double-tap to open; the triangle shows what is inside")
        } else {
            // A folder the space never wrote a page for: a name only.
            label.foregroundStyle(.secondary)
        }
    }

    private func row(_ info: HypermediaDocumentInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.title)
                .font(titleFamily.isEmpty ? .body : Font.custom(titleFamily, size: 13))
                .lineLimit(2)
            HStack(spacing: 6) {
                // The parents, without the space itself — the row is on
                // the space's own list. Inside a folder they are the
                // folder standing right above, so they are left out;
                // a search, which flattens, needs them back.
                let parents = showsParents ? Array(info.breadcrumbs.dropFirst()) : []
                if !parents.isEmpty {
                    Text(parents.joined(separator: " › "))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let updated = info.updated {
                    if !parents.isEmpty { Text("·") }
                    Text(updated, format: .dateTime.year().month(.abbreviated).day())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .tag(info.id)
        .contextMenu {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.id, forType: .string)
            }
            Button("Open on the Web") {
                let path = info.path.isEmpty ? "" : "/" + info.path.joined(separator: "/")
                if let url = URL(string: "https://\(space.domain)\(path)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .accessibilityLabel(info.title)
        .accessibilityHint("Double-tap to open")
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
