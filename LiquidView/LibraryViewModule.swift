import SwiftUI

/// One way of seeing the library, packaged for exchange.
///
/// Origami Text's views are modules so community members can write and share
/// them as single Swift files. To create one:
///
///  1. Write a SwiftUI view (or two) in one file. Read library data from
///     the environment model — `@Environment(AppModel.self) private var
///     model` — e.g. `model.index.byID`, `model.index.backlinks`, or the
///     derivations in LibraryInsights. Navigate with
///     `model.openInLibrary(doc)`, `model.open(doc, fragment:)`, or
///     `model.openTranspointing(from:to:)`.
///  2. At the bottom of the file, expose a `LibraryViewModule` describing
///     it: a stable id, sidebar name, SF Symbol, and how to build its panes.
///  3. Add that module to `LibraryViewRegistry.modules` — one line.
///
/// The sidebar entry, selection, and routing then work automatically.
@MainActor
struct LibraryViewModule: Identifiable {
    /// Stable identifier, lowercase and hyphenated, e.g. "hot-paragraphs".
    let id: String
    /// Sidebar label.
    let name: String
    /// Sidebar SF Symbol name.
    let systemImage: String
    /// The content column (middle pane) while this view is selected.
    let makeContent: () -> AnyView
    /// The detail pane, or nil to leave the standard reader in charge.
    /// The closure may also return nil to fall back conditionally — e.g.
    /// Authors shows its page only once an author is selected.
    var makeDetail: ((AppModel) -> AnyView?)? = nil
    /// Whole-library views (the Weave, Connections, the AI reports) set
    /// this so the document list column steps aside while they are active:
    /// the view already speaks for every document.
    var hidesDocumentList = false
}

/// The installed views, in sidebar order.
@MainActor
enum LibraryViewRegistry {
    // The JSON "digital letters" view modules are obsolete (EPUB-only
    // pivot). Emptied here so nothing surfaces them; the view files are
    // being removed and new views will be built fresh against EPUB +
    // Visual-Meta.
    static let modules: [LibraryViewModule] = []

    static func module(id: String) -> LibraryViewModule? {
        modules.first { $0.id == id }
    }

    static func module(for item: SidebarItem?) -> LibraryViewModule? {
        guard case .view(let id)? = item else { return nil }
        return module(id: id)
    }
}
