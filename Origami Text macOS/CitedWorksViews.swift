import SwiftUI

/// Library ▸ References: the master list — every work the library cites,
/// each once, however many papers cite it and however each wrote it —
/// from the record Check Library Now keeps in the community folder
/// (origami-cited-works.json). Sorted by the Title, Author or Date tab
/// (a second click reverses); each row shows what it is sorted by, with
/// its gravest warning beside.
struct CitedWorksListView: View {
    @Environment(AppModel.self) private var model
    /// Bumped when the record is read again, so the list redraws.
    @State private var readStamp = 0
    /// Title, Author or Date, and which way — a second click on the
    /// chosen tab reverses it, as every list's tabs do.
    @AppStorage("citedWorksSortKey") private var sortKey = "title"
    @AppStorage("citedWorksSortAscending") private var ascending = true

    typealias Entry = (key: String, work: ReferenceStatus.CitedWork)

    /// One work per entry: a work found by its title is kept under both
    /// its title and its DOI, and shows once.
    private var entries: [Entry] {
        _ = readStamp
        let all = ReferenceStatus.shared
        return all.filter { key, work in
            guard key.hasPrefix("title:"), let doi = work.doi else { return true }
            return all[doi] == nil
        }
        .map { ($0.key, $0.value) }
    }

    /// The entry's title, as shown.
    static func title(_ entry: Entry) -> String {
        entry.work.title ?? entry.key.replacingOccurrences(of: "title:", with: "")
    }

    /// The first author's surname, for sorting by author.
    private static func surname(_ entry: Entry) -> String? {
        guard let first = entry.work.authors?.first else { return nil }
        let name = first.contains(",") ? String(first.split(separator: ",")[0]) : first
        return (name.split(separator: " ").last.map(String.init) ?? name)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private var sorted: [Entry] {
        // The foot Find, as every list has it.
        let found = entries.filter { entry in
            model.matchesFind([entry.work.title, entry.work.authors?.joined(separator: " "), entry.work.doi]
                .compactMap { $0 }.joined(separator: " "))
        }
        func byTitle(_ a: Entry, _ b: Entry) -> Bool {
            Self.title(a).localizedCaseInsensitiveCompare(Self.title(b)) == .orderedAscending
        }
        // Works without an author, or without a year, stand last either way.
        switch sortKey {
        case "author":
            return found.sorted { a, b in
                switch (Self.surname(a), Self.surname(b)) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byTitle(a, b)
                }
            }
        case "date":
            return found.sorted { a, b in
                switch (a.work.year, b.work.year) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return byTitle(a, b)
                }
            }
        default:
            return found.sorted { ascending ? byTitle($0, $1) : byTitle($1, $0) }
        }
    }

    /// Choosing a work shows its card — closing a paper opened from the
    /// last card, which otherwise keeps the reading pane.
    private var chooseWork: Binding<String?> {
        Binding(
            get: { model.selectedCitedWorkKey },
            set: { key in
                if key != nil { model.openEPUB = nil }
                model.selectedCitedWorkKey = key
            })
    }

    var body: some View {
        let check = CitedWorksCheck.shared
        VStack(spacing: 0) {
            ReferenceSortTabs(key: $sortKey, ascending: $ascending)
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(check.isRunning ? "Gathering the References" : "No Master List Yet",
                          systemImage: "text.quote")
                } description: {
                    Text(check.isRunning
                         ? "Checking \(check.done.formatted()) of \(check.total.formatted()) cited works…"
                         : "Check Library Now looks up every work your library cites — once each, politely — and keeps what it finds in the community folder, for this Mac and your headset.")
                } actions: {
                    if !check.isRunning {
                        Button("Check Library Now") {
                            check.start(docs: model.index.allByID.mapValues(\.doc),
                                        folder: model.index.folderURL)
                        }
                        .disabled(model.index.folderURL == nil)
                    }
                }
            } else {
                List(selection: chooseWork) {
                    Section {
                        ForEach(sorted, id: \.key) { entry in
                            CitedWorkRow(entry: entry, sortKey: sortKey)
                                .tag(entry.key)
                                // A click on the work already chosen is no
                                // change of selection: it still brings its
                                // card back over a paper opened from it.
                                .simultaneousGesture(TapGesture().onEnded {
                                    model.openEPUB = nil
                                })
                        }
                    } header: {
                        Text("\(entries.count.formatted()) works cited")
                    }
                }
                .contentMargins(.top, 0, for: .scrollContent)
            }
        }
        // The record as the folder holds it, read again while a check
        // writes it.
        .task {
            await ReferenceStatus.adoptShared(from: model.index.folderURL)
            readStamp += 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await ReferenceStatus.adoptShared(from: model.index.folderURL)
                readStamp += 1
            }
        }
    }
}

/// Title | Author | Date above the references, in the shelf's own tab
/// look: a click chooses, a second click reverses. Title starts A–Z,
/// Author A–Z by surname, Date newest first.
struct ReferenceSortTabs: View {
    @Binding var key: String
    @Binding var ascending: Bool
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(ThemeColorOverrides.tickKey) private var themeTick = 0
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .highContrast }

    var body: some View {
        HStack(spacing: 2) {
            tab("Title", value: "title", startsAscending: true)
            tab("Author", value: "author", startsAscending: true)
            tab("Date", value: "date", startsAscending: false)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tab(_ title: String, value: String, startsAscending: Bool) -> some View {
        let chosen = key == value
        return Button {
            if chosen { ascending.toggle() } else { key = value; ascending = startsAscending }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if chosen {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .foregroundStyle(theme.textColor(for: colorScheme) ?? Color.primary)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(chosen ? (theme.background(for: colorScheme)
                                ?? Color(nsColor: .controlBackgroundColor)) : .clear)
                .shadow(color: .black.opacity(chosen ? 0.12 : 0), radius: 1, y: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chosen ? "Click again to reverse" : "Sort by \(title.lowercased())")
    }
}

/// One work, saying what it is sorted by: its title under Title, its
/// authors under Author, both (and the year) under Date — with its
/// gravest warning beside, whichever.
private struct CitedWorkRow: View {
    let entry: CitedWorksListView.Entry
    let sortKey: String

    var body: some View {
        let work = entry.work
        let warning = ReferenceStatus.standingWarning(doi: work.doi, title: work.title ?? "",
                                                      year: work.year)
        let authors = work.authors?.joined(separator: ", ")
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let warning { MarkPill(mark: warning) }
                switch sortKey {
                case "author":
                    Text(authors ?? "Unknown author")
                        .font(.system(size: 12.5))
                        .foregroundStyle(authors == nil ? .secondary : .primary)
                        .lineLimit(2)
                default:
                    Text(CitedWorksListView.title(entry))
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                }
            }
            if sortKey == "date" {
                let byline = [authors, work.year.map(String.init)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                if !byline.isEmpty {
                    Text(byline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
    }
}

/// A keyword as a small pill, coloured by what it says.
private struct MarkPill: View {
    let mark: ReferenceStatus.Mark

    var body: some View {
        let color: Color = switch mark.tone {
        case .alarm: .red
        case .caution: .orange
        case .info: .blue
        case .good: .green
        case .positive: .accentColor
        case .quiet: .secondary
        }
        Text(mark.text)
            .font(.system(size: 10, weight: mark.pill ? .semibold : .regular))
            .foregroundStyle(color)
            .padding(.horizontal, mark.pill ? 6 : 0)
            .padding(.vertical, mark.pill ? 1 : 0)
            .overlay {
                if mark.pill { Capsule().strokeBorder(color.opacity(0.7), lineWidth: 1) }
            }
            .help(mark.detail)
    }
}

/// Everything the master list knows of one work: what it is, whether it
/// can be trusted (each keyword with its meaning and evidence), what it
/// says, how it is cited, and which of the shelf's papers cite it — each
/// opening on a click.
struct CitedWorkDetailView: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        if let work = ReferenceStatus.shared[key] {
            ScrollView {
                details(work)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("Not in the Master List", systemImage: "quote.opening")
        }
    }

    /// The first passage of a paper that cites the work: the paper's own
    /// reference that is this work — the same DOI, or the same folded
    /// title — and the first paragraph whose [cite:] names it.
    static func citingParagraph(in record: EPUBRecord, of work: ReferenceStatus.CitedWork,
                                key: String, model: AppModel) -> String? {
        guard let doc = model.index.allByID[record.id]?.doc ?? model.index.byID[record.id]?.doc
        else { return nil }
        let wantedDOI = work.doi
        let wantedTitles = Set([work.title, key.hasPrefix("title:") ? String(key.dropFirst(6)) : nil]
            .compactMap { $0 }.map(ReferenceStatus.normalizedTitle))
        let keys = Set(doc.references.compactMap { reference -> String? in
            let bib = BibTeXRecord.records(in: reference.bibtex).first
            let doi = ReferenceStatus.cleanDOI(bib?.fields["doi"])
            if let wantedDOI, doi == wantedDOI { return reference.id }
            let title = bib?.title.isEmpty == false ? bib!.title : (reference.citedAs ?? "")
            if ReferenceStatus.sharedKey(doi: doi, title: title) == key { return reference.id }
            return wantedTitles.contains(ReferenceStatus.normalizedTitle(title)) ? reference.id : nil
        })
        guard !keys.isEmpty else { return nil }
        return doc.body?.first { paragraph in
            paragraph.text.contains("[cite") && !keys.isDisjoint(with: Transpoint.citationKeys(in: paragraph.text))
        }?.id
    }

    @ViewBuilder private func details(_ work: ReferenceStatus.CitedWork) -> some View {
        let live = work.live
        let marks = ReferenceStatus.marks(for: .init(doi: work.doi, title: work.title ?? "",
                                                     year: work.year))
        VStack(alignment: .leading, spacing: 14) {
            Text(work.title ?? key.replacingOccurrences(of: "title:", with: ""))
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
            let byline = [work.authors?.joined(separator: ", "), work.year.map(String.init), work.venue]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !byline.isEmpty {
                Text(byline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !marks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(marks, id: \.self) { mark in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            MarkPill(mark: mark)
                            if !mark.meaning.isEmpty {
                                Text(mark.meaning)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let summary = work.summary, !summary.isEmpty {
                Text(summary).font(.body.weight(.medium))
            }
            if let abstract = work.abstract, !abstract.isEmpty {
                Text(abstract).textSelection(.enabled)
                if let source = work.abstractSource {
                    Text("Abstract via \(source)").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let topics = live?.topics, !topics.isEmpty {
                Text("Topics: " + topics.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let byYear = live?.citationsByYear, !byYear.isEmpty {
                Text("Cited by year: " + byYear.prefix(6)
                    .map { "\(String($0.year)) \($0.count.formatted())" }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let doi = work.doi, let url = URL(string: "https://doi.org/" + doi) {
                    Link("doi:\(doi)", destination: url)
                }
                if live?.isOpenAccess == true, let free = live?.openAccessURL,
                   let url = URL(string: free) {
                    Link("Read the free copy", destination: url)
                }
            }
            .font(.callout)
            let citing = (work.citedBy ?? []).compactMap { id in
                model.epubRecords.first { $0.id == id }
            }
            if !citing.isEmpty {
                Divider()
                Text(citing.count == 1 ? "Cited by 1 paper on your shelf"
                                       : "Cited by \(citing.count) papers on your shelf")
                    .font(.headline)
                ForEach(citing) { record in
                    Button {
                        // Opened where it cites the work, the passage
                        // flashing — the way a quote link lands.
                        if let place = Self.citingParagraph(in: record, of: work, key: key, model: model) {
                            model.openEPUB(address: record.id, fragment: place)
                        } else {
                            model.openEPUBRecord(withID: record.id)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.title)
                            Text(record.author).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Checked \(work.checked.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}
