import SwiftUI

/// One way of seeing the library, packaged for exchange.
///
/// Origami Text's views are modules so community members can write and share
/// them as single Swift files. To create one:
///
///  1. Write a SwiftUI view (or two) in one file. Read the library from
///     the environment model — `@Environment(AppModel.self) private var
///     model`. Every opened EPUB stands in `model.index.byID` as a
///     structured document, re-imported from its package: the Visual-Meta
///     metadata (title, authors, date, venue), the headings, the defined
///     concepts, the citations and references, and the body paragraphs
///     with their stable ids. `model.index.backlinks` holds the typed
///     links between books, and LibraryInsights derives hot paragraphs,
///     attention, and the health report over the same shelf. Navigate with
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
    /// What "Show in <View>" hands this view: `.text` for views about
    /// text snippets (the selected words travel), `.note` for views
    /// about documents as nodes (the whole document travels). The view
    /// picks the payload up with `model.takeShowInPayload(for:)`.
    var showInAppetite: ShowInAppetite = .note

    enum ShowInAppetite { case text, note }
}

/// Home, Work, and aliases as the reader defined them — a private
/// reading preference, never written into any document. (Knowledge
/// Space's definition, kept so the travelling view modules compile.)
nonisolated enum AppLocations {
    static let homeKey = "homeLocation"
    static let workKey = "workLocation"
    static let aliasesKey = "locationAliases"

    /// The label when one applies — "Home", "Work", or an alias — else nil.
    static func label(for location: String?) -> String? {
        guard let location else { return nil }
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        if matches(trimmed, UserDefaults.standard.string(forKey: homeKey)) { return "Home" }
        if matches(trimmed, UserDefaults.standard.string(forKey: workKey)) { return "Work" }
        return alias(for: trimmed)
    }

    /// Every alias: the full stored place name → the name displayed for it.
    static var aliases: [String: String] {
        UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
    }

    static func alias(for location: String) -> String? {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        return aliases.first {
            $0.key.caseInsensitiveCompare(trimmed) == .orderedSame
        }?.value
    }

    /// Sets, replaces, or (with nil or empty) removes the alias for a
    /// stored place name.
    static func setAlias(_ alias: String?, for location: String) {
        var all = aliases
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        if let existing = all.keys.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            all.removeValue(forKey: existing)
        }
        if let alias = alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty {
            all[trimmed] = alias
        }
        UserDefaults.standard.set(all, forKey: aliasesKey)
    }

    /// The location as displayed: the label when one applies, otherwise
    /// the full place name itself.
    static func display(_ location: String?) -> String? {
        label(for: location) ?? location
    }

    private static func matches(_ location: String, _ defined: String?) -> Bool {
        guard let defined = defined?.trimmingCharacters(in: .whitespaces),
              !defined.isEmpty else { return false }
        return defined.caseInsensitiveCompare(location) == .orderedSame
    }
}

/// Knowledge Space's theme palette, shimmed onto the system colours —
/// the travelling view modules reference it, so the files port unchanged.
enum AppGreys {
    static var page: Color { Color(nsColor: .textBackgroundColor) }
    static var column: Color { Color(nsColor: .windowBackgroundColor) }
    static var text: Color { .primary }
    static var heading: Color { .primary }
    static var quietText: Color { .secondary }
}

/// The installed views, in sidebar order — the experimental views shared
/// with Knowledge Space (the lab's interaction experiments), written
/// against the same AppModel API so the files travel between the two
/// apps unchanged.
@MainActor
enum LibraryViewRegistry {
    static let modules: [LibraryViewModule] = [
        AskLibraryView.module,
        SphereWeaveView.module,
        DocumentWebView.module,
        WeaveView.module,
        AuthorsCircleView.module,
        PlacesView.module,
        CalendarEventsView.module,
        AttentionsView.module,
        StrangerView.module,
        TrailsView.module,
        GeometriesView.module,
        GlossaryView.module,
        GlossarySpaceView.module,
        KNavView.module,
        HotParagraphsView.module,
        AIInsightsView.module,
        ThemesView.module,
        OpenQuestionsView.module,
        AgreementsView.module,
        DisagreementsView.module,
        TheDealView.module,
        ZView.module,
        ZigZagView.module,
        ZZNavigatorView.module,
        HealthDashboardView.module,
    ]

    static func module(id: String) -> LibraryViewModule? {
        #if DEBUG
        _ = uniqueIDCheck
        #endif
        return modules.first { $0.id == id }
    }

    static func module(for item: SidebarItem?) -> LibraryViewModule? {
        guard case .view(let id)? = item else { return nil }
        return module(id: id)
    }

    #if DEBUG
    /// A module is reached by its id, so two modules sharing one leave a
    /// view unreachable — the sidebar shows both rows, but every click on
    /// either opens whichever the registry lists first. That is silent in
    /// a release build and maddening to a module author, so it trips an
    /// assertion here. Evaluated once, on first lookup.
    private static let uniqueIDCheck: Void = {
        let counts = Dictionary(grouping: modules.map(\.id), by: { $0 })
        let duplicates = counts.filter { $0.value.count > 1 }.keys.sorted()
        assert(duplicates.isEmpty,
               "Duplicate view-module id(s): \(duplicates.joined(separator: ", ")). "
               + "Each LibraryViewModule needs a unique id.")
    }()
    #endif
}
