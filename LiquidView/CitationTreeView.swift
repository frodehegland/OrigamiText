import SwiftUI

/// A library view that shows a selected citation's place in the scholarly
/// web: which library books cite it (inbound) and what it itself cites
/// (outbound, from CitationGraph). Opened via "View as Tree" in the
/// citation card sheet; the target travels via AppModel.citationTreeTarget.
struct CitationTreeView: View {
    @Environment(AppModel.self) private var model

    @State private var graph: CitationGraph.Entry?
    @State private var fetching = false
    @State private var citedByDocs: [LiquidDoc] = []
    /// True once the synchronous library scan has run — prevents empty
    /// state messages from flashing before the task fires.
    @State private var scanned = false

    private var target: AppModel.CitationTreeTarget? { model.citationTreeTarget }

    var body: some View {
        if let target {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    rootCard(target)
                    inboundSection
                    outboundSection(target)
                }
                .padding()
            }
            .task(id: target.graphKey) {
                // Reset when the target changes.
                scanned = false
                graph = CitationGraph.cached(forKey: target.graphKey)
                citedByDocs = findCitedBy(target: target)
                scanned = true
                guard graph == nil, CitationGraph.isEnabled else { return }
                fetching = true
                graph = await CitationGraph.references(
                    title: target.title,
                    author: target.author,
                    year: target.year,
                    doi: target.doi)
                fetching = false
            }
        } else {
            ContentUnavailableView(
                "No Citation Selected",
                systemImage: "arrow.triangle.branch",
                description: Text("Open a citation card and choose \"View as Tree\".")
            )
        }
    }

    // MARK: - Sub-views

    @ViewBuilder private func rootCard(_ target: AppModel.CitationTreeTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Selected citation", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(target.title.isEmpty ? "Untitled" : target.title)
                .font(.headline)
            let byLine = [target.author,
                          target.year.map(String.init) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            if !byLine.isEmpty {
                Text(byLine).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var inboundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("In your library", systemImage: "arrow.down.to.line")
                .font(.headline)
            if !scanned {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning library\u{2026}")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if citedByDocs.isEmpty {
                Text("No books in your library reference this work.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(citedByDocs) { doc in
                    Button {
                        model.openInLibrary(doc)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "book.closed")
                                .font(.callout)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(doc.title)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                if !doc.author.isEmpty {
                                    Text(doc.author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                }
            }
        }
    }

    @ViewBuilder private func outboundSection(_ target: AppModel.CitationTreeTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What this work cites", systemImage: "arrow.up.from.line")
                .font(.headline)
            if let graph {
                if graph.found {
                    Text("via \(graph.source)")
                        .font(.caption).foregroundStyle(.tertiary)
                    ForEach(Array(graph.references.enumerated()), id: \.offset) { _, cited in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cited.title).font(.callout)
                                let line = [cited.authors,
                                            cited.year.map(String.init) ?? ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · ")
                                if !line.isEmpty {
                                    Text(line).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.vertical, 2)
                    }
                } else {
                    Text("The scholarly services do not list this work's references.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if fetching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching references\u{2026}")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if !CitationGraph.isEnabled {
                Text("Citation graph lookup is turned off in Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if scanned {
                // Enabled but fetch returned nil — offer a manual retry.
                Button("Fetch references") {
                    fetching = true
                    Task { @MainActor in
                        graph = await CitationGraph.references(
                            title: target.title,
                            author: target.author,
                            year: target.year,
                            doi: target.doi)
                        fetching = false
                    }
                }
                .font(.callout)
            } else {
                // Task hasn't run yet — show nothing (avoids a flash).
                EmptyView()
            }
        }
    }

    // MARK: - Inbound scan

    /// Scans all library documents for references that match the target
    /// by DOI (preferred) or lowercased title.
    private func findCitedBy(target: AppModel.CitationTreeTarget) -> [LiquidDoc] {
        let targetDOI = target.doi?.lowercased()
        let targetTitle = target.title.lowercased()
        guard !targetTitle.isEmpty else { return [] }

        return model.index.byID.values
            .map(\.doc)
            .filter { doc in
                doc.references.contains { ref in
                    guard let record = BibTeXRecord.records(in: ref.bibtex).first else { return false }
                    if let doi = targetDOI, !doi.isEmpty,
                       let refDOI = record.fields["doi"]?.lowercased(), !refDOI.isEmpty {
                        return doi == refDOI
                    }
                    return record.title.lowercased() == targetTitle
                }
            }
            .sorted { $0.listedDate > $1.listedDate }
    }

    // MARK: - Module registration

    static let module = LibraryViewModule(
        id: "citation-tree",
        name: "Citation Tree",
        systemImage: "arrow.triangle.branch",
        makeContent: { AnyView(CitationTreeView()) })
}
