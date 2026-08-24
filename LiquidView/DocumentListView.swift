import SwiftUI

/// The "All Documents" list: title/author/date rows, sidecar and duplicate
/// badges, and unreadable files greyed out at the bottom.
struct DocumentListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries = model.filteredEntries
        List(selection: model.listSelection) {
            ForEach(entries) { entry in
                DocumentRow(entry: entry)
                    .tag(entry.id)
                    .contextMenu {
                        DocumentRowMenu(entry: entry)
                    }
            }
            UnreadableFilesSection()
        }
        .overlay {
            if entries.isEmpty && model.index.unreadableFiles.isEmpty && !model.index.isScanning {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No Documents" : "No Results",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
        }
    }
}

/// The ways through the Library shelf: everything, the unread, the
/// pinned, by date, by title, one folder's worth, or the books set
/// aside.
enum LibraryListMode: Hashable {
    case all
    case folder(String)
    case inbox
    case topOfPile
    case timeline
    case alphabetical
    case setAside
}

/// The pile actions every EPUB row's context menu offers: Pin (first
/// in every list), Set Aside (out of the lists, into the sidebar's Set
/// Aside shelf — or back), then Move to Trash.
struct EPUBPileMenu: View {
    @Environment(AppModel.self) private var model
    let record: EPUBRecord

    var body: some View {
        Toggle("Pin", isOn: Binding(
            get: { model.isTopOfPile(record) },
            set: { _ in model.toggleTopOfPile(record) }))
        if model.isSetAside(record) {
            Button("Bring Back") { model.bringBack(record) }
        } else {
            Button("Set Aside") { model.setAside(record) }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { model.trashEPUB(record) }
    }
}

/// The Library shelf: opened EPUBs — all of them, the unread Inbox, the
/// Timeline (newest publication first), Alphabetical, or one folder's
/// worth. Rows reopen the rendered page; a context menu files them into
/// folders. Timeline and Alphabetical can narrow to unread via their
/// sidebar items' context menus.
struct EPUBLibraryListView: View {
    @Environment(AppModel.self) private var model
    var mode: LibraryListMode = .all
    @AppStorage("libraryTimelineUnreadOnly") private var timelineUnreadOnly = false
    @AppStorage("libraryAlphabeticalUnreadOnly") private var alphabeticalUnreadOnly = false

    private var records: [EPUBRecord] {
        switch mode {
        case .all:
            return model.pinnedFirst(model.epubRecords(inFolder: nil))
        case .folder(let name):
            return model.pinnedFirst(model.epubRecords(inFolder: name))
        case .inbox:
            return model.pinnedFirst(
                model.epubRecords(inFolder: nil).filter { model.isUnread($0) })
        case .topOfPile:
            return model.epubRecords(inFolder: nil).filter { model.isTopOfPile($0) }
        case .timeline:
            return model.pinnedFirst(model.epubRecords(inFolder: nil)
                .filter { !timelineUnreadOnly || model.isUnread($0) }
                .sorted { publicationDate($0) > publicationDate($1) })
        case .alphabetical:
            return model.pinnedFirst(model.epubRecords(inFolder: nil)
                .filter { !alphabeticalUnreadOnly || model.isUnread($0) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        case .setAside:
            return model.epubSetAsideRecords
        }
    }

    /// The book's own date when it carries one, else when it arrived.
    private func publicationDate(_ record: EPUBRecord) -> Date {
        record.dateISO.flatMap(LiquidDoc.parseISO8601) ?? record.openedAt
    }

    private var inFolder: Bool {
        if case .folder = mode { return true }
        return false
    }

    var body: some View {
        let records = records
        // Selection IS the open book: the row highlights natively, and
        // selecting a row opens it in the reader.
        List(selection: epubListSelection(model)) {
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if model.isTopOfPile(record) {
                            Image(systemName: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(EmberIconLabelStyle.ember)
                        }
                        Text(record.title)
                            .fontWeight(model.isUnread(record) ? .bold : .regular)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(record.author)
                        if let filed = model.epubFolder(for: record.id), !inFolder {
                            Text("· \(filed)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // The reader's whole-document annotation, quiet
                    // lines under the author.
                    if let note = model.documentAnnotationNote(forRecordID: record.id) {
                        Text(note)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .tag(record.id)
                .contextMenu {
                    Menu("File Under") {
                        ForEach(model.epubFolders, id: \.self) { name in
                            Button(name) { model.fileEPUB(record.id, under: name) }
                        }
                        if !model.epubFolders.isEmpty { Divider() }
                        Button("New Folder…") { model.promptNewEPUBFolder(fileAfter: record.id) }
                    }
                    if model.epubFolder(for: record.id) != nil {
                        Button("Remove from Folder") { model.unfileEPUB(record.id) }
                    }
                    Divider()
                    EPUBPileMenu(record: record)
                }
            }
            // The headset's wishes: cited works asked for as books from
            // the Map's citation cards — an ember dot each, the
            // download link where the citation carried one, until
            // acquired or dismissed.
            if case .timeline = mode, !model.acquisitions.isEmpty {
                Section("To acquire") {
                    ForEach(model.acquisitions) { wanted in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(EmberIconLabelStyle.ember)
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(wanted.title)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text([wanted.author,
                                          wanted.year.map(String.init) ?? ""]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · "))
                                    if let doi = wanted.doi, !doi.isEmpty,
                                       let url = URL(string: doi.hasPrefix("http")
                                            ? doi : "https://doi.org/\(doi)") {
                                        Link("doi", destination: url)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                model.removeAcquisition(wanted.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Dismiss this wish")
                        }
                    }
                }
            }
        }
        // The list starts right under the toolbar, no dead air.
        .contentMargins(.top, 0, for: .scrollContent)
        .overlay {
            if records.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "books.vertical")
                } description: {
                    Text(emptyDescription)
                }
            }
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .folder: "Empty Folder"
        case .inbox: "Nothing Unread"
        case .topOfPile: "Nothing Pinned"
        case .setAside: "Nothing Set Aside"
        default: "No EPUBs Yet"
        }
    }

    private var emptyDescription: String {
        switch mode {
        case .folder(let name):
            "File EPUBs into “\(name)” from the All list's context menu."
        case .inbox:
            "Every opened EPUB has been read. New arrivals gather here until they are opened."
        case .topOfPile:
            "Right-click a book and choose Pin — it gathers here and floats first in every list."
        case .setAside:
            "Right-click a book and choose Set Aside to tuck it out of the lists — it waits here until brought back."
        case .timeline where timelineUnreadOnly, .alphabetical where alphabeticalUnreadOnly:
            "Nothing unread — this list is narrowed to unread (right-click its sidebar item to show everything)."
        default:
            "Open an EPUB (⌘O) or drag one in, and it appears here."
        }
    }
}

/// The book lists' shared selection: the highlighted row is the book
/// open in the reader, and selecting a row opens it.
@MainActor
func epubListSelection(_ model: AppModel) -> Binding<String?> {
    Binding(
        get: { model.openEPUBRecordID },
        set: { id in
            if let id { model.openEPUBRecord(withID: id) }
        }
    )
}

/// One opened-EPUB row: title (bold while unread) and author, tagged so
/// its List selects — and thereby opens — it. Reused by the author and
/// venue lists; their Lists take `epubListSelection`.
struct EPUBRecordRow: View {
    @Environment(AppModel.self) private var model
    let record: EPUBRecord
    /// When shown inside a folder or author group, the redundant subtitle
    /// line can be dropped.
    var showsSubtitle: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if model.isTopOfPile(record) {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(EmberIconLabelStyle.ember)
                }
                Text(record.title)
                    .fontWeight(model.isUnread(record) ? .bold : .regular)
                    .lineLimit(2)
            }
            if showsSubtitle {
                Text(record.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The reader's whole-document annotation, quiet lines
            // under the author.
            if let note = model.documentAnnotationNote(forRecordID: record.id) {
                Text(note)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(record.id)
        .contextMenu {
            EPUBPileMenu(record: record)
        }
    }
}

/// Views ▸ Authors: the authors of record, names only, each with how
/// many books they authored here. Click a name for their documents.
/// Automatic — nothing the user curates.
struct AuthorsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let authors = model.epubAuthors
        List {
            ForEach(authors, id: \.self) { author in
                Button {
                    model.sidebarSelection = .epubAuthor(author)
                } label: {
                    HStack {
                        Label(author, systemImage: "person")
                        Spacer()
                        Text("\(model.epubRecords(byAuthor: author).count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if authors.isEmpty {
                ContentUnavailableView {
                    Label("No Authors Yet", systemImage: "person.2")
                } description: {
                    Text("Open an EPUB and its author appears here.")
                }
            }
        }
    }
}

/// Views ▸ Authors ▸ one author: what they authored, newest first. The
/// header row leads back to the author list.
struct AuthorBooksListView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        List(selection: epubListSelection(model)) {
            Section {
                // The pinned books simply first, as in every list.
                ForEach(model.pinnedFirst(model.epubRecords(byAuthor: name))) { record in
                    EPUBRecordRow(record: record, showsSubtitle: false)
                }
            } header: {
                Button {
                    model.sidebarSelection = .authors
                } label: {
                    Label(name, systemImage: "chevron.backward")
                }
                .buttonStyle(.plain)
                .help("Back to Authors")
            }
        }
        // The list starts right under the toolbar, no dead air.
        .contentMargins(.top, 0, for: .scrollContent)
        .overlay {
            if model.epubRecords(byAuthor: name).isEmpty {
                ContentUnavailableView {
                    Label(name, systemImage: "person")
                } description: {
                    Text("Nothing by this author is in the library now.")
                }
            }
        }
    }
}

/// Library ▸ Journals (or Proceedings — Settings ▸ Layout chooses the
/// word): the venues the opened EPUBs are part of, names only, each
/// with how many books it holds here. Click a venue for its books.
/// Automatic — read from each book's Visual-Meta or package metadata.
struct JournalsListView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.venueLabelKey) private var venueLabel = "Journals"

    var body: some View {
        let venues = model.epubPublications
        List {
            ForEach(venues, id: \.self) { venue in
                Button {
                    model.sidebarSelection = .epubPublication(venue)
                } label: {
                    HStack {
                        Label(venue, systemImage: "newspaper")
                        Spacer()
                        Text("\(model.epubRecords(inPublication: venue).count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    // Papers write the same venue slightly differently;
                    // declaring one the same as another folds them.
                    Menu("Is the Same As") {
                        ForEach(venues.filter {
                            $0.caseInsensitiveCompare(venue) != .orderedSame
                        }, id: \.self) { other in
                            Button(other) { model.mergeVenue(venue, into: other) }
                        }
                    }
                    let aliases = model.aliasesFiled(under: venue)
                    if !aliases.isEmpty {
                        Menu("Separate") {
                            ForEach(aliases, id: \.self) { alias in
                                Button(alias) { model.separateVenue(alias) }
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if venues.isEmpty {
                ContentUnavailableView {
                    Label("No \(venueLabel) Yet", systemImage: "newspaper")
                } description: {
                    Text("Books gather here when they declare the journal or proceedings they are part of — in their Visual-Meta or the EPUB's own metadata.")
                }
            }
        }
    }
}

/// Library ▸ Journals ▸ one venue: the books it holds here, the pinned
/// ones simply first. The header is the venue's name; the sidebar is
/// the way back. Books Set Aside stay hidden behind a pill at the foot
/// of the list, and unfold below it when asked.
struct JournalBooksListView: View {
    @Environment(AppModel.self) private var model
    let name: String
    /// The Set Aside books stay tucked behind the foot pill until asked.
    @State private var showsSetAside = false

    var body: some View {
        let shown = model.pinnedFirst(model.epubRecords(inPublication: name))
        let aside = model.epubSetAsideRecords(inPublication: name)
        List(selection: epubListSelection(model)) {
            Section {
                ForEach(shown) { record in
                    EPUBRecordRow(record: record)
                }
                if !aside.isEmpty {
                    setAsidePill(count: aside.count)
                    if showsSetAside {
                        ForEach(aside) { record in
                            EPUBRecordRow(record: record)
                                .opacity(0.55)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: "moon.zzz")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                }
            } header: {
                Text(name)
            }
        }
        // The list starts right under the toolbar, no dead air.
        .contentMargins(.top, 0, for: .scrollContent)
        .overlay {
            if shown.isEmpty, aside.isEmpty {
                ContentUnavailableView {
                    Label(name, systemImage: "newspaper")
                } description: {
                    Text("Nothing from this venue is in the library now.")
                }
            }
        }
    }

    /// The pill at the foot of the articles: outlined while the Set
    /// Aside books rest hidden, filled while they stand revealed below.
    private func setAsidePill(count: Int) -> some View {
        HStack {
            Spacer()
            Button {
                withAnimation(.snappy) { showsSetAside.toggle() }
            } label: {
                Text("Set Aside")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .foregroundStyle(showsSetAside
                                     ? AnyShapeStyle(Color.white)
                                     : AnyShapeStyle(.secondary))
                    .background(Capsule().fill(showsSetAside ? Color.accentColor : .clear))
                    .overlay {
                        if !showsSetAside {
                            Capsule().strokeBorder(.secondary.opacity(0.6))
                        }
                    }
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(showsSetAside
                  ? "Tuck the Set Aside books away again"
                  : "Reveal the \(count) Set Aside book\(count == 1 ? "" : "s") below")
            Spacer()
        }
        .listRowSeparator(.hidden)
        .padding(.vertical, 4)
    }

}

/// Views ▸ People: the people the user is tracking. Automatic extraction of
/// names from the EPUBs is a later step; for now this lists what the user
/// has added (with “Add Person” in the sidebar).
struct PeopleListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.viewPeople, id: \.self) { name in
                Label(name, systemImage: "person")
                    .tag(SidebarItem.person(name))
                    .contextMenu {
                        Button("Remove") { model.removePerson(name) }
                    }
            }
        }
        .overlay {
            if model.viewPeople.isEmpty {
                ContentUnavailableView {
                    Label("No People Yet", systemImage: "person.crop.circle")
                } description: {
                    Text("Add people with “Add Person” in the sidebar. Pulling names out of the EPUBs automatically is a later step.")
                }
            }
        }
    }
}

/// Views ▸ a single person. Where the documents that mention this person
/// will gather once name extraction is added.
struct PersonListView: View {
    let name: String

    var body: some View {
        ContentUnavailableView {
            Label(name, systemImage: "person")
        } description: {
            Text("Documents mentioning \(name) will gather here once names are pulled from the EPUBs.")
        }
    }
}

/// Views ▸ Concepts: the concepts the user is tracking. Pulling concepts
/// out of the EPUBs is a later step; this lists what the user has added.
struct ConceptsListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.viewConcepts, id: \.self) { name in
                Label(name, systemImage: "tag")
                    .tag(SidebarItem.concept(name))
                    .contextMenu {
                        Button("Remove") { model.removeConcept(name) }
                    }
            }
        }
        .overlay {
            if model.viewConcepts.isEmpty {
                ContentUnavailableView {
                    Label("No Concepts Yet", systemImage: "lightbulb")
                } description: {
                    Text("Add concepts with “Add Concept” in the sidebar. Pulling concepts out of the EPUBs automatically is a later step.")
                }
            }
        }
    }
}

/// Views ▸ a single concept. Where the documents that contain this concept
/// will gather once concept extraction is added.
struct ConceptListView: View {
    let name: String

    var body: some View {
        ContentUnavailableView {
            Label(name, systemImage: "tag")
        } description: {
            Text("Documents containing \(name) will gather here once concepts are pulled from the EPUBs.")
        }
    }
}

/// Received ▸ Inbox: everything from other people — the unread on top,
/// bold; the recently read below, plain, only the last twenty (Dialog's
/// timeline keeps them all). A letter being read stays put until the
/// reader moves on; a small person icon marks what is addressed for the
/// user's attention.
struct InboxListView: View {
    @Environment(AppModel.self) private var model
    /// Highlighted while a file is dragged over the inbox to be imported.
    @State private var isDropTargeted = false

    var body: some View {
        let entries = model.inboxEntries
        let unread = entries.filter { model.isUnread($0.doc) }
        let read = entries.filter { !model.isUnread($0.doc) }
        List(selection: model.listSelection) {
            ForEach(unread) { row($0) }
            // Not a hairline: a soft bar marks the shelf edge between
            // what waits and what has been read.
            if !unread.isEmpty && !read.isEmpty {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            ForEach(read) { row($0) }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(model.searchText.isEmpty ? "Nothing Received" : "No Results",
                          systemImage: "tray")
                } description: {
                    Text("Letters and other documents from the community arrive here — unread in bold, the recently read below them. Drop an EPUB here to import it.")
                }
            }
        }
        // Drop an EPUB (or other importable file) onto the inbox to import
        // it into a new draft.
        .dropDestination(for: URL.self) { urls, _ in
            let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
            guard !epubs.isEmpty else { return false }
            for url in epubs { model.openFile(at: url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    private func row(_ entry: IndexEntry) -> some View {
        DocumentRow(entry: entry)
            .tag(entry.id)
            .contextMenu {
                Menu("File") {
                    FileUnderMenuItems(doc: entry.doc)
                }
                Divider()
                DocumentRowMenu(entry: entry)
            }
    }
}

/// The letters ordered strictly by date under month headers, the newest
/// on top.
struct TimelineListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: model.listSelection) {
                ForEach(model.timelineGroups, id: \.label) { group in
                    Section(group.label) {
                        // No explicit .id() here: it would defeat the
                        // row's .tag and clicks would stop selecting.
                        // scrollTo finds rows by their ForEach identity.
                        ForEach(group.entries) { entry in
                            DocumentRow(entry: entry, showsTime: true)
                                .tag(entry.id)
                                .contextMenu {
                                    DocumentRowMenu(entry: entry)
                                }
                        }
                    }
                }
            }
            // A document footer's Timeline menu arrives here: scroll to
            // the document, which opening has already selected.
            .task(id: model.timelineRevealID) {
                guard let id = model.timelineRevealID else { return }
                model.timelineRevealID = nil
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// The filing menu's contents: New… asks for a folder name, then the
/// folders in order — Archived last, the one folder that hides its
/// documents from the Timeline and the other lists. A filed document
/// shows its folder checked, and can be unfiled.
struct FileUnderMenuItems: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        Button("New…") { model.fileInNewFolder(doc) }
        Divider()
        ForEach(model.filingFolders, id: \.self) { folder in
            Button {
                model.fileDocument(doc, under: folder)
            } label: {
                if model.folder(for: doc) == folder {
                    Label(folder, systemImage: "checkmark")
                } else {
                    Text(folder)
                }
            }
        }
        if model.folder(for: doc) != nil {
            Divider()
            Button("Unfile") { model.unfile(doc) }
        }
    }
}

/// The when and the where at the end of a document being read. Each is
/// a door on ctrl-click: the place opens the Locations view on that
/// place; the date opens the Timeline on this document.
struct DocumentFooter: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let location = doc.location {
                Text(location)
                    .contextMenu {
                        Button("Location") { model.openLocations(highlighting: location) }
                    }
            }
            Text(doc.date?.displayText ?? doc.created.formatted(date: .abbreviated, time: .shortened))
                .contextMenu {
                    Button("Timeline") { model.openTimeline(revealing: doc) }
                }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 20)
    }
}

/// The one right-click answer for a library document row, shared by every
/// list that shows them — and it is the app-wide document menu, so an
/// action added in ContextActions.swift appears on every row at once.
struct DocumentRowMenu: View {
    let entry: IndexEntry

    var body: some View {
        ContextActionItems(target: .document(entry.doc))
    }
}

struct DocumentRow: View {
    @Environment(AppModel.self) private var model
    let entry: IndexEntry
    var showsTime = false

    private var isRetracted: Bool {
        model.index.retractedIDs.contains(entry.id)
    }

    /// Addressed for the reader's attention: a small person marks it.
    private var isForMyAttention: Bool {
        entry.doc.attention.contains { model.authorIdentity.matches(author: $0) }
    }

    /// Unread reads bold, mail-style, until the reader moves on from it.
    private var isUnread: Bool {
        model.isUnread(entry.doc)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if isForMyAttention {
                    Image(systemName: "person.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("For your attention")
                }
                Text(entry.doc.title)
                    .fontWeight(isUnread ? .bold : .medium)
                    .lineLimit(1)
                if isRetracted {
                    Image(systemName: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                        .help("Retracted by its author")
                }
                if entry.doc.isSidecar {
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(.secondary)
                        .help("Wraps an external file")
                }
                if entry.hasDuplicate {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Multiple files claim this document ID; showing the most recently modified one.")
                }
            }
            Text("\(entry.doc.displayAuthor) · \(dateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .opacity(isRetracted ? 0.55 : 1)
        .listRowSeparator(.hidden)
    }

    private var dateText: String {
        if let date = entry.doc.date { return date.displayText }
        return showsTime
            ? entry.doc.created.formatted(date: .abbreviated, time: .shortened)
            : entry.doc.created.formatted(date: .abbreviated, time: .omitted)
    }
}

struct UnreadableFilesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.index.unreadableFiles.isEmpty {
            Section("Unreadable Files") {
                ForEach(model.index.unreadableFiles) { file in
                    Label(file.fileURL.lastPathComponent, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.tertiary)
                        .help(file.reason)
                }
            }
        }
    }
}

extension AppModel {
    /// List selection mirrors the current destination; selecting a row
    /// navigates through the same history as link following.
    var listSelection: Binding<String?> {
        Binding(
            get: { self.current?.doc.id },
            set: { id in
                guard let id, id != self.current?.doc.id else { return }
                if let entry = self.index.byID[id] {
                    self.open(entry.doc)
                } else if let published = self.drafts.published.first(where: { $0.id == id }) {
                    // Dialog's timeline carries the user's own published
                    // copies too; they read like any document.
                    self.open(published)
                } else if let record = self.epubRecords.first(where: { $0.id == id }) {
                    // An opened EPUB listed in the inbox reopens its
                    // rendered page rather than the native reader.
                    self.openStoredEPUB(record)
                }
            }
        )
    }
}
