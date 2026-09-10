import SwiftUI

/// Sidebar ▸ Hypermedia ▸ a space: every document the space holds, newest
/// first. Click a row and the document opens in the reader. The space is
/// the authority — the list is fetched, not kept.
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

    @ViewBuilder private func content(for space: HypermediaSpace) -> some View {
        List(selection: $selectedID) {
            Section {
                ForEach(documents) { info in
                    row(info, space: space)
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

    private func row(_ info: HypermediaDocumentInfo, space: HypermediaSpace) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.title)
                .font(listTitleFamily.isEmpty ? .body : Font.custom(listTitleFamily, size: 13))
                .lineLimit(2)
            HStack(spacing: 6) {
                // The parents, without the space itself — the row is on
                // the space's own list.
                let parents = Array(info.breadcrumbs.dropFirst())
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
