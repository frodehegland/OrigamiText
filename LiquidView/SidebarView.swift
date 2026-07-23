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
    /// What has arrived for the user: the inbox — unread first and bold.
    /// It stands alone under the app's name, no section heading over it.
    static let received: [SidebarPlace] = [
        SidebarPlace(name: "Inbox", systemImage: "tray", item: .inbox),
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
        LibraryViewRegistry.modules.map {
            SidebarPlace(name: $0.name, systemImage: $0.systemImage, item: .view($0.id))
        }
    }

    static var sections: [(title: String, places: [SidebarPlace])] {
        // Notes is hidden while the notes work moves to the Knowledge
        // Space app — restore the ("Notes", notes) entry to bring it back.
        // The untitled first section renders without a heading.
        [("", received), ("Dialog", dialog), ("Outgoing", outgoing),
         ("Transcripts", transcripts), ("Books", books),
         ("Views", views)]
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
            ForEach(SidebarCatalog.sections, id: \.title) { section in
                if section.title.isEmpty {
                    // Inbox stands alone under the app's name — no
                    // heading, nothing to fold.
                    Section {
                        rows(of: section)
                    }
                } else {
                    // Finder-style: the header carries a reveal triangle,
                    // and a folded section keeps its contents out of sight.
                    Section(isExpanded: isExpanded(section.title)) {
                        rows(of: section)
                    } header: {
                        Text(section.title)
                    }
                }
            }
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

    @ViewBuilder
    private func rows(of section: (title: String, places: [SidebarPlace])) -> some View {
        ForEach(model.shownPlaces(of: section.places)) { place in
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

