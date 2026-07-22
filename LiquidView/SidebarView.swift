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
    static let library: [SidebarPlace] = [
        SidebarPlace(name: "Everything", systemImage: "books.vertical", item: .allDocuments),
        SidebarPlace(name: "Letters", systemImage: "envelope", item: .letters),
        SidebarPlace(name: "Transcripts", systemImage: "text.bubble", item: .transcripts),
        SidebarPlace(name: "Extracts", systemImage: "quote.opening", item: .extracts),
        SidebarPlace(name: "Timeline", systemImage: "clock", item: .timeline),
    ]

    static let myDocuments: [SidebarPlace] = [
        SidebarPlace(name: "Drafts", systemImage: "square.and.pencil", item: .drafts),
        SidebarPlace(name: "Published", systemImage: "paperplane", item: .published),
        SidebarPlace(name: "Archived", systemImage: "archivebox", item: .archived),
    ]

    static var views: [SidebarPlace] {
        LibraryViewRegistry.modules.map {
            SidebarPlace(name: $0.name, systemImage: $0.systemImage, item: .view($0.id))
        }
    }

    static var sections: [(title: String, places: [SidebarPlace])] {
        [("Library", library), ("My Documents", myDocuments), ("Views", views)]
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            ForEach(SidebarCatalog.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.places) { place in
                        Label(place.name, systemImage: place.systemImage)
                            .tag(place.item)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}
