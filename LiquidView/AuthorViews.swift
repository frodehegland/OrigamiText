import SwiftUI

/// Content pane for the Authors insight: everyone writing in the community.
struct AuthorListView: View {
    @Environment(AppModel.self) private var model
    /// A merge awaiting approval: the folded card shown in the contact
    /// form, and the records it replaces once saved.
    @State private var pendingMerge: PendingMerge?

    private struct PendingMerge: Identifiable {
        let merged: Person
        let originals: [Person]
        let absorbedName: String
        var id: String { merged.localID }
    }

    var body: some View {
        let authors = model.authorSummaries
        List(selection: authorSelection) {
            ForEach(authors) { author in
                HStack(spacing: 10) {
                    PersonAvatarView(name: author.name, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author.name)
                            .fontWeight(.medium)
                        Text(author.entries.isEmpty
                             ? "No letters yet"
                             : "\(author.entries.count) \(author.entries.count == 1 ? "letter" : "letters") · \(author.activeRangeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(author.name)
                .contextMenu {
                    // Two spellings, two cards, one person: fold another
                    // author into this one. The merged card shows for
                    // approval before anything changes.
                    if authors.count > 1 {
                        Menu("Merge with Another") {
                            ForEach(authors.filter { $0.id != author.id }) { other in
                                Button(other.name) {
                                    prepareMerge(of: author, absorbing: other)
                                }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if authors.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No Authors" : "No Results",
                    systemImage: "person.2"
                )
            }
        }
        .sheet(item: $pendingMerge) { merge in
            PersonFormView(person: merge.merged,
                           heading: "Approve Merge — “\(merge.absorbedName)” folds into this record") { approved in
                model.approveMergedPerson(approved, replacing: merge.originals)
            }
        }
    }

    /// Builds the folded card: the clicked author's record leads (made
    /// on the spot when they had none), the other's fills its gaps, and
    /// the absorbed name becomes an alias — so letters and statements
    /// under either name answer to the one record. Nothing changes
    /// until the card is approved.
    private func prepareMerge(of summary: AuthorSummary, absorbing otherSummary: AuthorSummary) {
        let base = model.people.person(named: summary.name) ?? Person(displayName: summary.name)
        let other = model.people.person(named: otherSummary.name) ?? Person(displayName: otherSummary.name)
        guard base.localID != other.localID else {
            model.showNote("“\(summary.name)” and “\(otherSummary.name)” already share one record.")
            return
        }
        pendingMerge = PendingMerge(merged: base.merged(absorbing: other),
                                    originals: [base, other],
                                    absorbedName: otherSummary.name)
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
    @State private var contactPerson: Person?

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
                    HStack(spacing: 14) {
                        PersonAvatarView(name: summary?.name ?? authorName, size: 88)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary?.name ?? authorName)
                                .font(.system(size: 32, weight: .bold, design: .serif))
                            Text(subtitle(for: summary, spoken: spoken))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Edit Record") {
                            let name = summary?.name ?? authorName
                            contactPerson = model.people.person(named: name)
                                ?? Person(displayName: name)
                        }
                    }
                    Divider().padding(.top, 8)
                }

                profileSection(for: summary?.name ?? authorName)

                if let summary {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Letters")
                            .font(.headline)
                        if summary.entries.isEmpty {
                            Text("No letters in the library yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
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
        .sheet(item: $contactPerson) { person in
            PersonFormView(person: person, heading: "Contact Record") { updated in
                model.people.upsert(updated)
            }
        }
    }

    /// Who this person is, in two registers: their public profile in
    /// their own words (from the contact record), and the personality the
    /// on-device model has built up from their letters — clearly marked,
    /// dated, and discardable.
    @ViewBuilder
    private func profileSection(for name: String) -> some View {
        if let publicProfile = model.people.person(named: name)?.publicProfile,
           !publicProfile.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Profile")
                    .font(.headline)
                Text(publicProfile)
                    .textSelection(.enabled)
            }
        }
        if let profile = model.profiles.profile(for: name), !profile.summary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Personality", systemImage: "sparkles")
                    .font(.headline)
                Text(profile.summary)
                    .textSelection(.enabled)
                if !profile.interests.isEmpty {
                    Text("Keeps returning to: \(profile.interests.joined(separator: ", "))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Built on this Mac from their letters, revised as new ones arrive — nothing leaves it. Updated \(profile.updated.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button("Discard Profile") {
                    model.profiles.removeProfile(for: name)
                }
            }
        }
    }

    private func subtitle(for summary: AuthorSummary?, spoken: [SpokenStatement]) -> String {
        var parts: [String] = []
        if let summary, !summary.entries.isEmpty {
            parts.append("\(summary.entries.count) \(summary.entries.count == 1 ? "letter" : "letters") · \(summary.activeRangeText)")
        }
        if !spoken.isEmpty {
            let meetings = Set(spoken.map(\.doc.id)).count
            parts.append("\(spoken.count) \(spoken.count == 1 ? "statement" : "statements") in \(meetings) \(meetings == 1 ? "meeting" : "meetings")")
        }
        if parts.isEmpty {
            return "No letters yet"
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
