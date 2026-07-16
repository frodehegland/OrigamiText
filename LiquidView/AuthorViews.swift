import SwiftUI

/// Content pane for the Authors insight: everyone writing in the community.
struct AuthorListView: View {
    @Environment(AppModel.self) private var model
    @State private var contactPerson: Person?

    var body: some View {
        let authors = model.authorSummaries
        List(selection: authorSelection) {
            ForEach(authors) { author in
                VStack(alignment: .leading, spacing: 2) {
                    Text(author.name)
                        .fontWeight(.medium)
                    Text("\(author.entries.count) \(author.entries.count == 1 ? "document" : "documents") · \(author.activeRangeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(author.name)
                .contextMenu {
                    Button("Contact Record…") {
                        contactPerson = model.people.person(named: author.name)
                            ?? Person(displayName: author.name)
                    }
                }
            }
        }
        .sheet(item: $contactPerson) { person in
            PersonFormView(person: person, heading: "Contact Record") { updated in
                model.people.upsert(updated)
            }
        }
        .navigationTitle("Authors")
        .overlay {
            if authors.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No Authors" : "No Results",
                    systemImage: "person.2"
                )
            }
        }
    }

    private var authorSelection: Binding<String?> {
        Binding(
            get: { model.selectedAuthor },
            set: { model.selectedAuthor = $0 }
        )
    }
}

/// Detail pane for a selected author: their documents plus the citation
/// relationships our backlink index already knows.
struct AuthorPageView: View {
    @Environment(AppModel.self) private var model
    let authorName: String

    var body: some View {
        // A person can be present as an author, as a meeting speaker, or
        // both — anyone the library has heard from gets a page.
        let summary = model.authorSummaries.first(where: { $0.id == authorName })
        let spoken = model.statements(by: authorName)
        if summary == nil, spoken.isEmpty {
            ContentUnavailableView("Author Not Found", systemImage: "person.slash")
        } else {
            content(for: summary, spoken: spoken)
        }
    }

    private func content(for summary: AuthorSummary?, spoken: [SpokenStatement]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary?.name ?? authorName)
                        .font(.system(size: 32, weight: .bold, design: .serif))
                    Text(subtitle(for: summary, spoken: spoken))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Divider().padding(.top, 8)
                }

                if let summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Documents")
                            .font(.headline)
                        ForEach(summary.entries) { entry in
                            Button {
                                model.openInLibrary(entry.doc)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: entry.doc.isSidecar ? "doc.richtext" : "doc.text")
                                        .foregroundStyle(.secondary)
                                    Text(entry.doc.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(entry.doc.listedDateText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    relationSection(title: "Cites", counts: summary.cites,
                                    emptyText: "Does not cite anyone yet.")
                    relationSection(title: "Cited By", counts: summary.citedBy,
                                    emptyText: "Not cited by anyone yet.")
                }

                if !spoken.isEmpty {
                    spokenSection(spoken)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle(summary?.name ?? authorName)
    }

    private func subtitle(for summary: AuthorSummary?, spoken: [SpokenStatement]) -> String {
        var parts: [String] = []
        if let summary {
            parts.append("\(summary.entries.count) \(summary.entries.count == 1 ? "document" : "documents") · \(summary.activeRangeText)")
        }
        if !spoken.isEmpty {
            let meetings = Set(spoken.map(\.doc.id)).count
            parts.append("\(spoken.count) \(spoken.count == 1 ? "statement" : "statements") in \(meetings) \(meetings == 1 ? "meeting" : "meetings")")
        }
        return parts.joined(separator: " · ")
    }

    /// What the person has said, newest meeting first; a statement opens
    /// its transcript scrolled to that paragraph.
    private func spokenSection(_ spoken: [SpokenStatement]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Said in Meetings")
                .font(.headline)
            ForEach(spoken) { statement in
                Button {
                    model.open(statement.doc, fragment: statement.paragraph.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statement.paragraph.displayText)
                            .lineLimit(2)
                        Text("\(statement.doc.title) · \(statement.doc.listedDateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func relationSection(title: String, counts: [AuthorLinkCount], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            if counts.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                FlowingChips(counts: counts) { name in
                    model.selectedAuthor = name
                }
            }
        }
    }
}

/// Clickable "Name (n)" chips for citation relationships.
private struct FlowingChips: View {
    let counts: [AuthorLinkCount]
    let onSelect: (String) -> Void

    var body: some View {
        // Simple wrapping via a lazy grid; enough at this scale.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(counts) { item in
                Button {
                    onSelect(item.name)
                } label: {
                    HStack(spacing: 5) {
                        Text(item.name)
                            .lineLimit(1)
                        Text("\(item.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension AuthorListView {
    /// The Authors view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "authors",
        name: "Authors",
        systemImage: "person.2",
        makeContent: { AnyView(AuthorListView()) },
        makeDetail: { model in
            model.selectedAuthor.map { AnyView(AuthorPageView(authorName: $0)) }
        }
    )
}
