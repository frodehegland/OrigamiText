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
    /// lists "All".
    static let received: [SidebarPlace] = [
        SidebarPlace(name: "All", systemImage: "tray.full", item: .epubsAll),
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

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    /// Sections the user has folded shut, by title — remembered across
    /// launches, the way Finder remembers its sidebar.
    @State private var collapsed: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "collapsedSidebarSections") ?? [])

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            // The Files shelf of opened EPUBs ("All", the user's folders,
            // and a "+"), then the authoring shelf. There is no Inbox:
            // unread EPUBs simply show bold in the Files list.
            filesSection
            viewsSection
            authorSection
        }
        .listStyle(.sidebar)
        // The app's name stands over the list, above Received — as
        // Knowledge Space's sidebar carries its own.
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("Origami")
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 18)
        }
        .navigationTitle("Origami")
        // Starts equal to the document list — the reference proportions
        // give each flanking column 195 of the 1120-point default window.
        .navigationSplitViewColumnWidth(min: 180, ideal: 195)
    }

    /// The authoring shelf: drafts written or imported here, which export
    /// as Origami Text EPUBs. Origami Text is a reader first, but until
    /// there is other software that writes the format, it lets people
    /// author too (import Word, edit, export EPUB).
    @ViewBuilder
    private var authorSection: some View {
        Section {
            Label("Drafts", systemImage: "square.and.pencil")
                .tag(SidebarItem.drafts)
            Button {
                model.newDraft()
            } label: {
                Label("New", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Button {
                model.importDocumentFile()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Production")
        }
    }

    /// Ways into the opened EPUBs by who and what they hold: Authors (the
    /// authors of record, automatic), then People and Concepts — user-curated
    /// buckets added the way folders are. How names and concepts are pulled
    /// from the EPUBs is a later step; for now People and Concepts hold what
    /// the user adds.
    @ViewBuilder
    private var viewsSection: some View {
        Section(isExpanded: isExpanded("Views")) {
            Label("Authors", systemImage: "person.2")
                .tag(SidebarItem.authors)

            Label("People", systemImage: "person.crop.circle")
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
        } header: {
            Text("Views")
        }
    }

    /// The Files shelf: "All" opened EPUBs, the user's folders, and a "+"
    /// to add another folder.
    @ViewBuilder
    private var filesSection: some View {
        Section(isExpanded: isExpanded("Files")) {
            Label("All", systemImage: "tray.full")
                .tag(SidebarItem.epubsAll)
            ForEach(model.epubFolders, id: \.self) { folder in
                Label(folder, systemImage: "folder")
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
            Text("Files")
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

