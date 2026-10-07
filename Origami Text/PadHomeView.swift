import SwiftUI
import UniformTypeIdentifiers

// iPad's home: the Mac's left column (SidebarView.swift) beside the
// shelf — the same title, sections, rows and foot, in the same order,
// so the two read as one app. Places the iPad can fill open their
// lists; places that live only on the Mac so far keep their row and
// say so, rather than vanishing. Keep the rows in step with the Mac's
// SidebarView. The iPhone keeps ReadHomeView.

/// One place in the iPad's left column.
enum PadPlace: Hashable {
    // EPUB
    case inbox, pinned, authors, papers, journals, mine
    // Hypermedia, Folders, XR
    case hypermedia, addFolder, graphs, timelines
    // Views
    case annotations, people, addPerson, conceptSpace, trackedConcepts, addConcept
    case ask, glossary, lineage, editViews
    // The foot
    case intro
}

/// The Mac sidebar's icons in the lab's ember orange — EmberIconLabelStyle's
/// iPad twin (that file builds for the Mac alone). Keep the colour in step.
struct PadEmberLabelStyle: LabelStyle {
    static let ember = Color(red: 0.72, green: 0.42, blue: 0.06)

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .foregroundStyle(Self.ember)
        }
    }
}

struct PadHomeView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var place: PadPlace? = .papers
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var choosingEPUB = false
    @State private var choosingFolder = false
    @State private var showsSettings = false
    @State private var openFailedName: String?
    /// Sections folded shut, by title — the Mac's key and first-run
    /// folding of XR and Views.
    @State private var collapsed: Set<String> = PadHomeView.initialCollapsed()
    @AppStorage("authorName") private var authorName = ""

    private static func initialCollapsed() -> Set<String> {
        let defaults = UserDefaults.standard
        var collapsed = Set(defaults.stringArray(forKey: "collapsedSidebarSections") ?? [])
        if !defaults.bool(forKey: "sidebarFoldsXRAndViews") {
            collapsed.formUnion(["XR", "Views"])
            defaults.set(Array(collapsed), forKey: "collapsedSidebarSections")
            defaults.set(true, forKey: "sidebarFoldsXRAndViews")
        }
        return collapsed
    }

    /// The reader's own row: their surname, as on the Mac.
    private var myLastName: String {
        let name = authorName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Mine" : (name.components(separatedBy: " ").last ?? name)
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            NavigationStack {
                PadPlaceView(place: place ?? .papers,
                             openEPUB: { choosingEPUB = true },
                             chooseFolder: { choosingFolder = true })
                    .navigationDestination(item: $model.readerRecordID) { recordID in
                        PhoneReaderView(docID: recordID)
                    }
            }
            // A new place starts its own stack, as a Mac sidebar click does.
            .id(place)
        }
        // Reading takes the screen; the column returns with the shelf.
        .onChange(of: model.isReading) {
            withAnimation { columns = model.isReading ? .detailOnly : .all }
        }
        // ReadHomeView's chores, kept in step: import, the community
        // folder, failures spoken, the scan and the standing's beat.
        .fileImporter(isPresented: $choosingEPUB,
                      allowedContentTypes: [.epub],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task {
                var last: EPUBRecord?
                for url in urls {
                    if let record = await model.openEPUBFile(at: url) { last = record }
                }
                if let last {
                    model.readerRecordID = last.id
                } else if !urls.isEmpty {
                    openFailedName = urls.first?.lastPathComponent ?? "the file"
                }
            }
        }
        .alert("Could Not Open", isPresented: Binding(
            get: { openFailedName != nil },
            set: { if !$0 { openFailedName = nil } })) {
            Button("OK", role: .cancel) { openFailedName = nil }
        } message: {
            Text("\(openFailedName ?? "The file") would not open as an EPUB. If it lives in iCloud Drive, make sure it has finished downloading, then try again.")
        }
        .alert("Could Not Save", isPresented: Binding(
            get: { model.storageFailure != nil },
            set: { if !$0 { model.storageFailure = nil } })) {
            Button("OK", role: .cancel) { model.storageFailure = nil }
        } message: {
            Text(model.storageFailure ?? "Check free space and iCloud, then try again.")
        }
        .fileImporter(isPresented: $choosingFolder,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.openFolder(url) }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { model.scanFolderForEPUBs() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                model.adoptSharedStanding()
            }
        }
        .sheet(isPresented: $showsSettings) {
            PhoneSettingsView()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: The column

    private var sidebar: some View {
        VStack(spacing: 0) {
            // The app's name over the list, as on the Mac.
            Text("Origami Text")
                .font(.headline)
                .fontWeight(.regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 12)
            List(selection: $place) {
                librarySection
                hypermediaSection
                foldersSection
                xrSection
                viewsSection
            }
            .listStyle(.sidebar)
            .labelStyle(PadEmberLabelStyle())
            // The foot, under a rule: the guide, Settings, and Contact.
            VStack(alignment: .leading, spacing: 14) {
                Divider()
                Button {
                    place = .intro
                } label: {
                    Label("Intro", systemImage: "book")
                }
                Button {
                    showsSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Button {
                    let subject = "Origami Text Feedback"
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                        ?? "Origami%20Text%20Feedback"
                    if let url = URL(string: "mailto:frode@hegland.com?subject=\(subject)") {
                        openURL(url)
                    }
                } label: {
                    Label("Contact", systemImage: "envelope")
                }
            }
            .buttonStyle(.plain)
            .labelStyle(PadEmberLabelStyle())
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var librarySection: some View {
        Section(isExpanded: isExpanded("Library")) {
            Label("Inbox", systemImage: "tray")
                .fontWeight(model.inboxHasUnopened ? .bold : .regular)
                .tag(PadPlace.inbox)
            Label("Pinned", systemImage: "pin")
                .tag(PadPlace.pinned)
            Label("Authors", systemImage: "person.2")
                .tag(PadPlace.authors)
            Label("Papers", systemImage: "doc.text")
                .tag(PadPlace.papers)
            Label("Journals", systemImage: "newspaper")
                .tag(PadPlace.journals)
            Label(myLastName, systemImage: "person.fill")
                .tag(PadPlace.mine)
        } header: {
            Text("EPUB")
        }
    }

    private var hypermediaSection: some View {
        Section(isExpanded: isExpanded("Hypermedia")) {
            Label("Add Space", systemImage: "plus")
                .foregroundStyle(.secondary)
                .tag(PadPlace.hypermedia)
        } header: {
            Text("Hypermedia")
        }
    }

    private var foldersSection: some View {
        Section(isExpanded: isExpanded("Folders")) {
            Label("Add Folder", systemImage: "plus")
                .foregroundStyle(.secondary)
                .tag(PadPlace.addFolder)
        } header: {
            Text("Folders")
        }
    }

    private var xrSection: some View {
        Section(isExpanded: isExpanded("XR")) {
            Label("Graphs", systemImage: "chart.line.uptrend.xyaxis")
                .tag(PadPlace.graphs)
            Label("Timelines", systemImage: "calendar.day.timeline.left")
                .tag(PadPlace.timelines)
        } header: {
            Text("XR")
        }
    }

    private var viewsSection: some View {
        Section(isExpanded: isExpanded("Views")) {
            Label("Annotations", systemImage: "highlighter")
                .tag(PadPlace.annotations)
            Label("People", systemImage: "person.crop.circle")
                .tag(PadPlace.people)
            Label("Add Person", systemImage: "plus")
                .foregroundStyle(.secondary)
                .tag(PadPlace.addPerson)
            Label("Concept Space", systemImage: "sparkles.rectangle.stack")
                .tag(PadPlace.conceptSpace)
            Label("Tracked Concepts", systemImage: "lightbulb")
                .tag(PadPlace.trackedConcepts)
            Label("Add Concept", systemImage: "plus")
                .foregroundStyle(.secondary)
                .tag(PadPlace.addConcept)
            // The Mac's three default view modules (defaultShownIDs).
            Label("Ask", systemImage: "questionmark.bubble")
                .tag(PadPlace.ask)
            Label("Glossary", systemImage: "character.book.closed")
                .tag(PadPlace.glossary)
            Label("Lineage", systemImage: "point.3.filled.connected.trianglepath.dotted")
                .tag(PadPlace.lineage)
            Label("Edit Views", systemImage: "slider.horizontal.3")
                .foregroundStyle(.secondary)
                .tag(PadPlace.editViews)
        } header: {
            Text("Views")
        }
    }

    private func isExpanded(_ title: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(title) },
            set: { expanded in
                if expanded {
                    collapsed.remove(title)
                } else {
                    collapsed.insert(title)
                }
                UserDefaults.standard.set(Array(collapsed), forKey: "collapsedSidebarSections")
            }
        )
    }
}

// MARK: - What a place shows

/// The right-hand side for one place: its list of books, or — for the
/// places the iPad does not hold yet — a plain word that they are the
/// Mac's for now.
private struct PadPlaceView: View {
    @Environment(PhoneModel.self) private var model
    let place: PadPlace
    let openEPUB: () -> Void
    let chooseFolder: () -> Void
    @State private var searchText = ""
    @State private var showsSetAside = false
    /// Papers' order, as the Mac's Title / Date tabs.
    @AppStorage("padPapersByDate") private var papersByDate = false
    @AppStorage("authorName") private var authorName = ""

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Import, the Mac's File menu here.
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Open EPUB\u{2026}", action: openEPUB)
                        Button(model.folderURL == nil
                               ? "Choose Community Folder\u{2026}"
                               : "Change Community Folder\u{2026}", action: chooseFolder)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch place {
        case .intro:
            PhoneGuideView()
        case .lineage:
            PhoneLineageView()
        case .inbox, .pinned, .authors, .papers, .journals, .mine:
            if model.epubRecords.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to Read Yet", systemImage: "books.vertical")
                } description: {
                    Text("Open an EPUB from Files, or choose the iCloud folder your community shares — everything published from a Mac appears here.")
                } actions: {
                    Button("Open EPUB\u{2026}", action: openEPUB)
                    Button("Choose Community Folder\u{2026}", action: chooseFolder)
                }
            } else {
                shelfList
                    .searchable(text: $searchText, placement: .toolbar, prompt: "Find")
            }
        default:
            ContentUnavailableView {
                Label(title, systemImage: "macbook")
            } description: {
                Text("\(title) is on Origami Text for Mac for now. It keeps its place in this column so the iPad and the Mac stay the same shape.")
            }
        }
    }

    private var title: String {
        switch place {
        case .inbox: "Inbox"
        case .pinned: "Pinned"
        case .authors: "Authors"
        case .papers: "Papers"
        case .journals: "Journals"
        case .mine: "Mine"
        case .hypermedia: "Hypermedia"
        case .addFolder: "Folders"
        case .graphs: "Graphs"
        case .timelines: "Timelines"
        case .annotations: "Annotations"
        case .people, .addPerson: "People"
        case .conceptSpace: "Concept Space"
        case .trackedConcepts, .addConcept: "Tracked Concepts"
        case .ask: "Ask"
        case .glossary: "Glossary"
        case .lineage: "Lineage"
        case .editViews: "Edit Views"
        case .intro: "Intro"
        }
    }

    @ViewBuilder
    private var shelfList: some View {
        VStack(spacing: 0) {
            if place == .papers {
                Picker("Order", selection: $papersByDate) {
                    Text("Title").tag(false)
                    Text("Date").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            List {
                switch place {
                case .inbox:
                    ForEach(model.inboxRecords.filter(matchesSearch)) { record in
                        PhoneShelfRow(record: record, emphasised: model.isUnopened(record))
                    }
                case .pinned:
                    ForEach(model.epubRecords.filter {
                        model.isTopOfPile($0) && matchesSearch($0)
                    }) { record in
                        PhoneShelfRow(record: record)
                    }
                case .authors:
                    ForEach(authors, id: \.name) { author in
                        NavigationLink {
                            PadAuthorView(author: author.name)
                        } label: {
                            HStack {
                                Text(author.name).lineLimit(1)
                                Spacer()
                                Text("\(author.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                case .journals:
                    ForEach(model.venues.filter { venue in
                        searchText.isEmpty || venue.localizedCaseInsensitiveContains(searchText)
                    }, id: \.self) { venue in
                        NavigationLink {
                            PhoneJournalView(venue: venue)
                        } label: {
                            HStack {
                                Label(venue, systemImage: "newspaper")
                                    .labelStyle(PadEmberLabelStyle())
                                    .lineLimit(2)
                                Spacer()
                                Text("\(model.records(inVenue: venue).count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                case .mine:
                    ForEach(model.pinnedFirst(model.epubRecords.filter {
                        !model.isSetAside($0) && isByMe($0) && matchesSearch($0)
                    })) { record in
                        PhoneShelfRow(record: record)
                    }
                default:
                    ForEach(papers.filter(matchesSearch)) { record in
                        PhoneShelfRow(record: record)
                    }
                    if !model.setAsideRecords.isEmpty {
                        Section {
                            if showsSetAside {
                                ForEach(model.setAsideRecords.filter(matchesSearch)) { record in
                                    PhoneShelfRow(record: record)
                                        .opacity(0.55)
                                }
                            }
                        } header: {
                            Button {
                                withAnimation { showsSetAside.toggle() }
                            } label: {
                                Label("Set Aside (\(model.setAsideRecords.count))",
                                      systemImage: showsSetAside ? "chevron.down" : "chevron.right")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if isEmptyHere {
                    ContentUnavailableView(emptyTitle, systemImage: "tray")
                }
            }
        }
    }

    // MARK: The lists' contents

    /// Every book on the shelf, by Title or by Date (newest first),
    /// pinned leading as everywhere.
    private var papers: [EPUBRecord] {
        guard papersByDate else { return model.alphabetical }
        return model.pinnedFirst(model.epubRecords.filter { !model.isSetAside($0) }
            .sorted { publicationDate($0) > publicationDate($1) })
    }

    private func publicationDate(_ record: EPUBRecord) -> Date {
        record.dateISO.flatMap(LiquidDoc.parseISO8601) ?? record.openedAt
    }

    /// Everyone who wrote what is on the shelf, by surname, with how
    /// many of their papers it holds.
    private var authors: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for record in model.epubRecords where !model.isSetAside(record) {
            for name in Set(record.authorList.map { $0.trimmingCharacters(in: .whitespaces) })
            where !name.isEmpty {
                counts[name, default: 0] += 1
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return counts
            .filter { query.isEmpty || $0.key.localizedCaseInsensitiveContains(query) }
            .map { (name: $0.key, count: $0.value) }
            .sorted { surnameKey($0.name) == surnameKey($1.name)
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : surnameKey($0.name) < surnameKey($1.name) }
    }

    /// The surname as a sort key, diacritics folded — the Mac's lastNameKey.
    private func surnameKey(_ name: String) -> String {
        let last = name.components(separatedBy: .whitespaces).last ?? name
        return last.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private func isByMe(_ record: EPUBRecord) -> Bool {
        let me = authorName.trimmingCharacters(in: .whitespaces)
        guard !me.isEmpty else { return false }
        return record.authorList.contains {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(me) == .orderedSame
        }
    }

    /// A book answers the Find field by its title or any of its authors.
    private func matchesSearch(_ record: EPUBRecord) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if record.title.localizedCaseInsensitiveContains(query) { return true }
        return record.authorList.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var isEmptyHere: Bool {
        guard searchText.isEmpty else { return false }
        switch place {
        case .pinned: return !model.epubRecords.contains { model.isTopOfPile($0) }
        case .mine: return !model.epubRecords.contains { isByMe($0) }
        default: return false
        }
    }

    private var emptyTitle: String {
        switch place {
        case .pinned: "Nothing Pinned"
        case .mine: authorName.isEmpty ? "Your Name Is Not Set" : "No EPUBs by You"
        default: ""
        }
    }
}

/// One author's papers on the shelf — tap a paper to read it, Back
/// returns to the list.
private struct PadAuthorView: View {
    @Environment(PhoneModel.self) private var model
    let author: String
    @State private var readerID: String?

    var body: some View {
        List(model.pinnedFirst(model.epubRecords.filter { record in
            !model.isSetAside(record) && record.authorList.contains {
                $0.trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(author) == .orderedSame
            }
        })) { record in
            PhoneShelfRow(record: record, opensLocally: $readerID)
        }
        .listStyle(.plain)
        .navigationTitle(author)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $readerID) { recordID in
            PhoneReaderView(docID: recordID)
        }
    }
}
