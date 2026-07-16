import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section("Library") {
                Label("Everything", systemImage: "books.vertical")
                    .tag(SidebarItem.allDocuments)
                Label("Letters", systemImage: "envelope")
                    .tag(SidebarItem.letters)
                Label("Transcripts", systemImage: "text.bubble")
                    .tag(SidebarItem.transcripts)
                Label("Extracts", systemImage: "quote.opening")
                    .tag(SidebarItem.extracts)
                Label("Timeline", systemImage: "clock")
                    .tag(SidebarItem.timeline)
            }
            Section("My Documents") {
                Label("Drafts", systemImage: "square.and.pencil")
                    .tag(SidebarItem.drafts)
                Label("Published", systemImage: "paperplane")
                    .tag(SidebarItem.published)
                Label("Archived", systemImage: "archivebox")
                    .tag(SidebarItem.archived)
            }
            Section("Views") {
                ForEach(LibraryViewRegistry.modules) { module in
                    Label(module.name, systemImage: module.systemImage)
                        .tag(SidebarItem.view(module.id))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }
}
