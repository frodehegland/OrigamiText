import SwiftUI

/// One place in the sidebar: a named, iconed destination. A single source
/// of truth shared by the split-view sidebar and the full-screen peek
/// panel, so the two can never drift apart.
struct SidebarPlace: Identifiable {
    let name: String
    let systemImage: String
    let item: SidebarItem
    var id: SidebarItem { item }
}

enum SidebarCatalog {
    /// The whole left column now that Origami Text is an EPUB reader: the
    /// Files shelf of opened EPUBs, with unread ones shown bold in the list
    /// (there is no separate Inbox). Everything else — the JSON "digital
    /// letters" views (Authors, Filed, Extracts, Drafts, Sent, Timeline,
    /// Books, Transcripts, Notes, and the Views modules) — is obsolete and
    /// gone; new views will be built fresh against the EPUB + Visual-Meta.
    /// The full-screen peek still needs a way back to the library, so it
    /// lists Chronological — every book, newest first.
    static let received: [SidebarPlace] = [
        SidebarPlace(name: "Time", systemImage: "clock", item: .epubsTimeline),
    ]

    /// The conversation itself: every letter to and from the user, the
    /// meetings, what was lifted from them, and everything filed.
    static let dialog: [SidebarPlace] = [
        SidebarPlace(name: "Timeline", systemImage: "clock", item: .timeline),
        SidebarPlace(name: "Transcripts", systemImage: "text.bubble", item: .transcripts),
        SidebarPlace(name: "Extracts", systemImage: "quote.opening", item: .extracts),
        SidebarPlace(name: "Filed", systemImage: "folder", item: .filed),
    ]

    /// The user's own hand: letters written, sent, and filed.
    static let outgoing: [SidebarPlace] = [
        SidebarPlace(name: "Drafts", systemImage: "square.and.pencil", item: .drafts),
        SidebarPlace(name: "Sent", systemImage: "paperplane", item: .published),
        SidebarPlace(name: "Filed", systemImage: "folder", item: .filedOutgoing),
    ]

    /// Notes, four ways in: by time, by place (country sections), by
    /// person, and by folder — Filed working exactly as the library's.
    static let notes: [SidebarPlace] = [
        SidebarPlace(name: "Timeline", systemImage: "clock", item: .notes),
        SidebarPlace(name: "Locations", systemImage: "mappin.and.ellipse", item: .noteLocations),
        SidebarPlace(name: "People", systemImage: "person", item: .notePeople),
        SidebarPlace(name: "Filed", systemImage: "folder", item: .filedNotes),
    ]

    /// The meetings: transcripts being prepared, the sent record, and
    /// the statements lifted out of them.
    static let transcripts: [SidebarPlace] = [
        SidebarPlace(name: "Drafts", systemImage: "square.and.pencil", item: .transcriptDrafts),
        SidebarPlace(name: "Sent", systemImage: "paperplane", item: .transcriptsPublished),
        SidebarPlace(name: "Extracts", systemImage: "quote.opening", item: .transcriptExtracts),
    ]

    /// The long form: books being written, published, and filed —
    /// ctrl-click Drafts (or ⌘⇧B) to begin one.
    static let books: [SidebarPlace] = [
        SidebarPlace(name: "Drafts", systemImage: "square.and.pencil", item: .bookDrafts),
        SidebarPlace(name: "Published", systemImage: "books.vertical", item: .booksPublished),
        SidebarPlace(name: "Filed", systemImage: "folder", item: .filedBooks),
    ]

    static var views: [SidebarPlace] {
        LibraryViewRegistry.modules
            // Authors is promoted to the top list, so it does not repeat here.
            .filter { $0.id != "authors" }
            .map { SidebarPlace(name: $0.name, systemImage: $0.systemImage, item: .view($0.id)) }
    }

    static var sections: [(title: String, places: [SidebarPlace])] {
        // Just Inbox now; the Files shelf is rendered separately in the
        // sidebar body. The JSON-era section arrays above are retired.
        [("", received)]
    }
}

/// Sidebar labels with their icons in the lab's ember orange — a
/// reddish orange that reads in light and dark mode alike. The text
/// keeps whatever style its row gives it.
struct EmberIconLabelStyle: LabelStyle {
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

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// Sections the user has folded shut, by title — remembered across
    /// launches, the way Finder remembers its sidebar.
    @State private var collapsed: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedSidebarSections") ?? [])
    /// What the venues shelf is called — Journals or Proceedings,
    /// chosen in Settings ▸ Layout.
    @AppStorage(AppSettings.venueLabelKey) private var venueLabel = "Journals"
    /// The Unread narrowing for Timeline and Alphabetical, toggled from
    /// their context menus; the lists read the same keys.
    @AppStorage("libraryTimelineUnreadOnly") private var timelineUnreadOnly = false
    @AppStorage("libraryAlphabeticalUnreadOnly") private var alphabeticalUnreadOnly = false

    /// The sidebar's own selection: the model's, but only when it names
    /// a row this list actually shows. The app has states with no
    /// sidebar row — the drafts editor after an import, a single
    /// author's list — and a macOS List whose selection names a missing
    /// row stops answering clicks. Those states read as no selection
    /// here; clicking any row still writes the model.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                guard let item = model.sidebarSelection, hasRow(for: item) else { return nil }
                return item
            },
            set: { newValue in
                // The List clears its selection during row updates;
                // only a real click on a row moves the app.
                guard let newValue else { return }
                // Choosing a place leaves the open book: the reader
                // otherwise keeps the whole detail pane and the click
                // would appear to do nothing.
                model.openEPUB = nil
                model.sidebarSelection = newValue
            }
        )
    }

    /// Whether the sidebar shows a row for this place.
    private func hasRow(for item: SidebarItem) -> Bool {
        switch item {
        case .epubsTopOfPile, .epubsTimeline, .epubsAlphabetical,
             .epubJournals, .authors, .annotations,
             .people, .concepts:
            true
        case .epubFolder(let name):
            model.epubFolders.contains(name)
        case .person(let name):
            model.viewPeople.contains(name)
        case .concept(let name):
            model.viewConcepts.contains(name)
        case .view(let id):
            LibraryViewRegistry.module(id: id) != nil && !model.isViewHidden(id)
        default:
            false
        }
    }

    var body: some View {
        // The title and the foot stand OUTSIDE the list, so all three
        // share the column's one material — no backing views (a second
        // material over the first reads lighter, like a highlight) and
        // nothing ever scrolls beneath them.
        VStack(spacing: 0) {
            // The app's name stands over the list — as Knowledge
            // Space's sidebar carries its own.
            Text("Origami Text")
                .font(.headline)
                .fontWeight(.regular)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 18)
            List(selection: selection) {
                // The Library shelf of opened EPUBs (the ways through
                // them, the user's folders, and a "+"), then the Views.
                librarySection
                viewsSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            // Every place's icon in the lab's ember orange — one style,
            // inherited by every Label in the list.
            .labelStyle(EmberIconLabelStyle())
            // The column's foot, under a rule: the built-in guide (the
            // user guide as an Origami EPUB, opened like any other
            // book), Settings, and Contact — always at hand.
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Button {
                    model.openIntroGuide()
                } label: {
                    Label("Intro", systemImage: "book")
                }
                .buttonStyle(.plain)
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.plain)
                Button {
                    let subject = "Origami Text Feedback"
                        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                        ?? "Origami%20Text%20Feedback"
                    if let url = URL(string: "mailto:frode@hegland.com?subject=\(subject)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Contact", systemImage: "envelope")
                }
                .buttonStyle(.plain)
                .help("Email your feedback to frode@hegland.com")
            }
            .labelStyle(EmberIconLabelStyle())
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Origami Text")
        // Wide enough for the longest place names ("Alphabetical",
        // journal names) with their counts beside them, at the large
        // sidebar text size too.
        .navigationSplitViewColumnWidth(min: 300, ideal: 330)
    }

    /// Ways into the opened EPUBs by who and what they hold: Authors (the
    /// authors of record, automatic), then People and Concepts — user-curated
    /// buckets added the way folders are. How names and concepts are pulled
    /// from the EPUBs is a later step; for now People and Concepts hold what
    /// the user adds.
    @ViewBuilder
    private var viewsSection: some View {
        Section(isExpanded: isExpanded("Views")) {
            // Badges inside the tags here too — see the Library shelf.
            Label("Authors", systemImage: "person.2")
                .badge(model.epubAuthors.count)
                .tag(SidebarItem.authors)

            Label("Annotations", systemImage: "highlighter")
                .badge(model.allAnnotations.count)
                .tag(SidebarItem.annotations)

            Label("People", systemImage: "person.crop.circle")
                .badge(model.viewPeople.count)
                .tag(SidebarItem.people)
            ForEach(model.viewPeople, id: \.self) { name in
                Label(name, systemImage: "person")
                    .tag(SidebarItem.person(name))
                    .contextMenu {
                        Button("Remove") { model.removePerson(name) }
                    }
            }
            Button {
                model.promptNewPerson()
            } label: {
                Label("Add Person", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Label("Concepts", systemImage: "lightbulb")
                .badge(model.viewConcepts.count)
                .tag(SidebarItem.concepts)
            ForEach(model.viewConcepts, id: \.self) { name in
                Label(name, systemImage: "tag")
                    .tag(SidebarItem.concept(name))
                    .contextMenu {
                        Button("Remove") { model.removeConcept(name) }
                    }
            }
            Button {
                model.promptNewConcept()
            } label: {
                Label("Add Concept", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            // The experimental views shared with Knowledge Space, each a
            // module in LibraryViewRegistry; curated with checkboxes in
            // Settings ▸ View Modules.
            ForEach(model.shownPlaces(of: SidebarCatalog.views)) { place in
                Label(place.name, systemImage: place.systemImage)
                    .tag(place.item)
            }
            Button {
                model.settingsTab = .modules
                openSettings()
            } label: {
                Label("Edit Views", systemImage: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Views")
        }
    }

    /// The Library shelf: the ways through the opened EPUBs — Top of
    /// Pile (the pinned books), Chronological (every book, newest
    /// first — the home list), Alphabetical, and the journals or
    /// proceedings they are part of — then the user's folders, the
    /// books set aside, and a "+" to add another folder. Every place
    /// carries its count on the right; Chronological and Alphabetical
    /// can narrow to unread from their context menus.
    @ViewBuilder
    private var librarySection: some View {
        let shown = model.epubRecords(inFolder: nil)
        Section(isExpanded: isExpanded("Library")) {
            // The badge sits INSIDE the tag: a badge applied over the
            // tag hides it from the List, and the row stops selecting.
            Label("Pinned", systemImage: "pin")
                .badge(shown.filter { model.isTopOfPile($0) }.count)
                .tag(SidebarItem.epubsTopOfPile)
            Label("Time", systemImage: "clock")
                .badge(timelineUnreadOnly
                       ? shown.filter { model.isUnread($0) }.count : shown.count)
                .tag(SidebarItem.epubsTimeline)
                .contextMenu {
                    Toggle("Unread", isOn: $timelineUnreadOnly)
                }
            Label("Alpha", systemImage: "textformat.abc")
                .badge(alphabeticalUnreadOnly
                       ? shown.filter { model.isUnread($0) }.count : shown.count)
                .tag(SidebarItem.epubsAlphabetical)
                .contextMenu {
                    Toggle("Unread", isOn: $alphabeticalUnreadOnly)
                }
            Label(venueLabel, systemImage: "newspaper")
                .badge(model.epubPublications.count)
                .tag(SidebarItem.epubJournals)
            ForEach(model.epubFolders, id: \.self) { folder in
                Label(folder, systemImage: "folder")
                    .badge(model.epubRecords(inFolder: folder).count)
                    .tag(SidebarItem.epubFolder(folder))
            }
            Button {
                model.promptNewEPUBFolder()
            } label: {
                Label("Add Folder", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Library")
        }
    }

    @ViewBuilder
    private func rows(of section: (title: String, places: [SidebarPlace])) -> some View {
        // Only the Views section is user-curated; the top places (Inbox,
        // Authors, Filed, Extracts) always show, even if their view module
        // is toggled off in Settings.
        let places = section.title == "Views"
            ? model.shownPlaces(of: section.places)
            : section.places
        ForEach(places) { place in
            Label(place.name, systemImage: place.systemImage)
                .fontWeight(place.item == .inbox && model.hasUnreadInbox
                            ? .bold : .regular)
                .tag(place.item)
                .contextMenu {
                    if place.item == .bookDrafts {
                        Button("New Book") { model.newBook() }
                    }
                }
        }
        // So many views — the list is the user's to curate, with
        // checkboxes in Settings → View Modules.
        if section.title == "Views" {
            Button {
                model.settingsTab = .modules
                openSettings()
            } label: {
                Label("Edit", systemImage: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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

