//
//  OverviewPicturesWindow.swift
//  Origami Text
//
//  Designed by Frode Hegland.
//  Copyright © 2026 Frode Alexander Hegland. All rights reserved.
//
//  The Pictures window, as in Author: every name the Overview found in a
//  book — or, opened from Settings, every name ever looked up — with its
//  picture, so
//  the writer can decide about each one. Don't Use keeps a picture but
//  stops showing it; Delete removes it and stops it being fetched again;
//  Find Alternatives searches Wikipedia and Wikimedia Commons with words
//  the writer can change ("Washington state") and offers every picture
//  found; Add Your Own takes a file, chosen or dropped on the card.
//
//  The pictures live in one store for all documents (Application Support,
//  not the .liquid package), so a choice made here holds wherever the name
//  appears. The sidebar switches between this document's names and every
//  name in the store, and filters by category; each category's switch
//  turns its pictures off, or on, everywhere.
//
//  Ported from Author (Liquid Author/Table Of Contents/
//  OverviewPicturesWindow.swift); keep the two in step.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class OverviewPicturesWindowController: NSWindowController {

    static let shared: OverviewPicturesWindowController = {
        let model = OverviewPicturesModel()
        let hosting = NSHostingController(rootView: OverviewPicturesView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1040, height: 740))
        window.minSize = NSSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        // A new name, so the larger size is not overridden by the frame an
        // earlier build remembered.
        window.setFrameAutosaveName("AuthorOverviewPicturesWindow2")
        let controller = OverviewPicturesWindowController(window: window)
        controller.model = model
        return controller
    }()

    private(set) var model: OverviewPicturesModel!

    /// Shows a document's names, or with no document every cached one.
    /// `jump` opens the text at a name's first mention, when there is text.
    func show(entities: [OverviewEntity], sections: [String: Int] = [:],
              documentName: String?, jump: ((String) -> Void)?) {
        // The other app may have found or chosen pictures since.
        OverviewPictureStore.shared.refreshFromDisk()
        model.documentEntities = entities
        model.sections = sections
        model.jump = jump
        model.documentName = documentName
        model.scope = documentName == nil ? .all : .document
        window?.title = documentName.map {
            String(format: NSLocalizedString("Pictures — %@", comment: "Pictures window title with document name"), $0)
        } ?? NSLocalizedString("All Pictures", comment: "Pictures window title opened from Settings")
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Every cached picture, for Settings.
    func showAll() {
        show(entities: [], documentName: nil, jump: nil)
    }
}

// MARK: - Model

@Observable
final class OverviewPicturesModel {

    enum Filter: String, CaseIterable, Identifiable {
        case all, shown, notUsed, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return NSLocalizedString("All", comment: "Pictures window filter")
            case .shown: return NSLocalizedString("Shown", comment: "Pictures window filter")
            case .notUsed: return NSLocalizedString("Not Used", comment: "Pictures window filter")
            case .none: return NSLocalizedString("No Picture", comment: "Pictures window filter")
            }
        }
    }

    enum Scope: Hashable {
        case document, all
    }

    /// The names in the document the window was opened from.
    var documentEntities: [OverviewEntity] = []
    var scope: Scope = .all
    /// One category, or nil for every one.
    var category: OverviewEntityKind?
    var filter: Filter = .all
    var sections: [String: Int] = [:]
    var documentName: String?
    var jump: ((String) -> Void)?

    /// Bumped on any change to the store — a picture arriving, one chosen
    /// — and read by everything drawn from the store, so all of it redraws.
    private(set) var storeTick = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: OverviewPictureStore.changed,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeTick += 1 }
        }
    }

    enum Status {
        case shown, notUsed, deleted, nothingFound, notYetLookedUp
    }

    func status(of entity: OverviewEntity) -> Status {
        _ = storeTick
        let store = OverviewPictureStore.shared
        guard let record = store.record(for: entity) else { return .notYetLookedUp }
        if record.deleted == true { return .deleted }
        guard record.title != nil, store.storedImage(for: entity) != nil else { return .nothingFound }
        return store.isHidden(entity) ? .notUsed : .shown
    }

    /// The names in scope: this document's, or every one in the store.
    var entities: [OverviewEntity] {
        _ = storeTick
        return scope == .document ? documentEntities : OverviewPictureStore.shared.allEntities
    }

    func count(of kind: OverviewEntityKind?) -> Int {
        guard let kind else { return entities.count }
        return entities.filter { $0.kind == kind }.count
    }

    var visible: [OverviewEntity] {
        entities.filter { entity in
            if let category, entity.kind != category { return false }
            switch (filter, status(of: entity)) {
            case (.all, _): return true
            case (.shown, .shown): return true
            case (.notUsed, .notUsed): return true
            case (.none, .deleted), (.none, .nothingFound), (.none, .notYetLookedUp): return true
            default: return false
            }
        }
    }

    /// The picture, even while not used, so the card can show what is kept.
    func image(for entity: OverviewEntity) -> NSImage? {
        _ = storeTick
        return OverviewPictureStore.shared.storedImage(for: entity)
    }
}

// MARK: - Window

struct OverviewPicturesView: View {

    @Bindable var model: OverviewPicturesModel
    @State private var alternativesFor: OverviewEntity?

    private let columns = [GridItem(.adaptive(minimum: 136), spacing: 10)]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            content
        }
        .sheet(item: $alternativesFor) { entity in
            AlternativesView(entity: entity) { alternativesFor = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let store = OverviewPictureStore.shared
        return VStack(alignment: .leading, spacing: 2) {
            if model.documentName != nil {
                sidebarHeading(NSLocalizedString("Show", comment: "Pictures window sidebar section"))
                sidebarRow(title: NSLocalizedString("This Book", comment: "Pictures window scope"),
                           symbol: "doc.text", selected: model.scope == .document) { model.scope = .document }
                sidebarRow(title: NSLocalizedString("All Books", comment: "Pictures window scope"),
                           symbol: "square.stack", selected: model.scope == .all) { model.scope = .all }
                Spacer().frame(height: 12)
            }

            sidebarHeading(NSLocalizedString("Categories", comment: "Pictures window sidebar section"))
            sidebarRow(title: NSLocalizedString("All Categories", comment: "Pictures window category"),
                       symbol: "square.grid.2x2", count: model.count(of: nil),
                       selected: model.category == nil) { model.category = nil }
            ForEach(OverviewEntityKind.allCases) { kind in
                HStack(spacing: 0) {
                    sidebarRow(title: kind.title, symbol: kind.symbol, count: model.count(of: kind),
                               selected: model.category == kind, dimmed: !store.isShown(kind)) { model.category = kind }
                    // The category's switch: off hides its pictures in every
                    // document and stops new ones being looked up.
                    Toggle("", isOn: Binding(get: { store.isShown(kind) },
                                             set: { store.setShown(kind, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .help(String(format: NSLocalizedString("Show pictures of %@ in Overview", comment: "Pictures window category switch"),
                                     kind.title.lowercased()))
                        .padding(.trailing, 8)
                }
            }

            Spacer()

            Text(NSLocalizedString("Kept on this Mac for every book — not inside any one of them — so a choice made here holds wherever the name appears.",
                                   comment: "Pictures window store explanation"))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
            Button(NSLocalizedString("Show in Finder", comment: "Pictures window button")) {
                NSWorkspace.shared.activateFileViewerSelecting([store.location])
            }
            .controlSize(.small)
            .padding([.horizontal, .bottom], 10)
        }
        .padding(.top, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }

    private func sidebarRow(title: String, symbol: String, count: Int? = nil, selected: Bool,
                            dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundColor(selected ? .white : .accentColor)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
                }
            }
            .foregroundColor(selected ? .white : .primary)
            .opacity(dimmed && !selected ? 0.5 : 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.headline)
                    Text(NSLocalizedString("From Wikipedia and Wikimedia Commons; only the names are sent. Drop an image on a card to use your own.",
                                           comment: "Pictures window explanation"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("", selection: $model.filter) {
                    ForEach(OverviewPicturesModel.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            .padding(16)

            Divider()

            if model.visible.isEmpty {
                VStack {
                    Spacer()
                    Text(model.entities.isEmpty
                         ? NSLocalizedString("No names found yet. Choose Overview at the foot of a book to find them.", comment: "Pictures window empty state")
                         : NSLocalizedString("Nothing in this view.", comment: "Pictures window empty filter"))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.visible) { entity in
                            PictureCard(entity: entity, model: model,
                                        findAlternatives: { alternativesFor = entity })
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var heading: String {
        let place = model.scope == .document
            ? NSLocalizedString("in this book", comment: "Pictures window heading scope")
            : NSLocalizedString("in all books", comment: "Pictures window heading scope")
        let what = model.category?.title ?? NSLocalizedString("All pictures", comment: "Pictures window heading, every category")
        var text = what + " " + place
        if let category = model.category, !OverviewPictureStore.shared.isShown(category) {
            text += " — " + NSLocalizedString("turned off", comment: "Pictures window heading: category switched off")
        }
        return text
    }
}

// MARK: - Card

private struct PictureCard: View {

    let entity: OverviewEntity
    let model: OverviewPicturesModel
    let findAlternatives: () -> Void

    @State private var isTargeted = false

    private var store: OverviewPictureStore { .shared }

    var body: some View {
        let status = model.status(of: entity)
        let record = store.record(for: entity)

        VStack(spacing: 4) {
            picture(status: status)
                .opacity(status == .notUsed ? 0.35 : 1)

            Text(entity.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Text(detail(status: status, record: record))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 26, alignment: .top)

            HStack(spacing: 6) {
                switch status {
                case .shown:
                    Button(NSLocalizedString("Don’t Use", comment: "Pictures window button")) {
                        store.setHidden(entity, true)
                    }
                case .notUsed:
                    Button(NSLocalizedString("Use", comment: "Pictures window button")) {
                        store.setHidden(entity, false)
                    }
                default:
                    Button(NSLocalizedString("Find…", comment: "Pictures window button: find a picture"), action: findAlternatives)
                }

                Menu {
                    Button(NSLocalizedString("Find Alternatives…", comment: "Pictures window menu"), action: findAlternatives)
                    Button(NSLocalizedString("Add Your Own…", comment: "Pictures window menu"), action: chooseOwn)
                    if status == .shown || status == .notUsed {
                        Button(NSLocalizedString("Delete Picture", comment: "Pictures window menu")) {
                            store.delete(entity)
                        }
                    }
                    if let page = record?.pageURL, let url = URL(string: page) {
                        Divider()
                        Button(NSLocalizedString("Open Source Page", comment: "Pictures window menu")) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    if let jump = model.jump, !entity.anchor.isEmpty {
                        Button(NSLocalizedString("Show in Text", comment: "Pictures window menu")) {
                            jump(entity.anchor)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .controlSize(.mini)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isTargeted ? 2 : 1)
        )
        .opacity(store.isShown(entity.kind) ? 1 : 0.5)
        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isTargeted, perform: dropped)
    }

    @ViewBuilder
    private func picture(status: OverviewPicturesModel.Status) -> some View {
        let side: CGFloat = 60
        let shape = RoundedRectangle(cornerRadius: entity.kind == .person ? side / 2 : 10)
        if let image = model.image(for: entity) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipShape(shape)
        } else {
            shape
                .fill(Color(nsColor: .quaternaryLabelColor))
                .frame(width: side, height: side)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                )
        }
    }

    private var symbol: String { entity.kind.symbol }

    private func detail(status: OverviewPicturesModel.Status, record: OverviewPictureRecord?) -> String {
        let sectionCount = model.sections[entity.key].map {
            $0 == 1 ? NSLocalizedString("1 section", comment: "Pictures window: mentioned in one section")
                    : String(format: NSLocalizedString("%ld sections", comment: "Pictures window: mentioned in sections"), $0)
        }
        let state: String
        switch status {
        case .shown, .notUsed:
            let prefix = status == .notUsed ? NSLocalizedString("Not used", comment: "Pictures window status") + " · " : ""
            state = prefix + [record?.title, record?.summary].compactMap { $0 }.joined(separator: " — ")
        case .deleted: state = NSLocalizedString("Deleted", comment: "Pictures window status")
        case .nothingFound: state = NSLocalizedString("No picture found that surely matches", comment: "Pictures window status")
        case .notYetLookedUp: state = NSLocalizedString("Not looked up yet", comment: "Pictures window status")
        }
        return [state, sectionCount].compactMap { $0 }.joined(separator: " · ")
    }

    private func chooseOwn() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(format: NSLocalizedString("Choose a picture for “%@”", comment: "Open panel message"), entity.name)
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        store.useOwn(image, for: entity)
    }

    /// An image dragged from Finder, a browser or Photos.
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                guard let image = object as? NSImage else { return }
                DispatchQueue.main.async { store.useOwn(image, for: entity) }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async { store.useOwn(image, for: entity) }
        }
        return true
    }
}

// MARK: - Alternatives

private struct AlternativesView: View {

    let entity: OverviewEntity
    let dismiss: () -> Void

    @State private var query: String
    @State private var candidates: [OverviewPictureCandidate] = []
    @State private var isSearching = false
    @State private var searched = false

    init(entity: OverviewEntity, dismiss: @escaping () -> Void) {
        self.entity = entity
        self.dismiss = dismiss
        _query = State(initialValue: entity.name)
    }

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(format: NSLocalizedString("Choose a picture for “%@”", comment: "Alternatives sheet heading"), entity.name))
                .font(.headline)
            HStack {
                TextField(NSLocalizedString("Search for", comment: "Alternatives search field"), text: $query)
                    .onSubmit(search)
                Button(NSLocalizedString("Search", comment: "Alternatives search button"), action: search)
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(NSLocalizedString("Add words to say which one you mean — “Washington state”, “Portland Oregon”.",
                                   comment: "Alternatives search hint"))
                .font(.caption)
                .foregroundColor(.secondary)

            ZStack {
                if isSearching {
                    ProgressView(NSLocalizedString("Looking on Wikipedia and Wikimedia Commons…", comment: "Alternatives progress"))
                } else if searched && candidates.isEmpty {
                    Text(NSLocalizedString("Nothing found. Try other words.", comment: "Alternatives empty"))
                        .foregroundColor(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(candidates) { candidate in
                                Button {
                                    OverviewPictureStore.shared.use(candidate, for: entity)
                                    dismiss()
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(nsImage: candidate.image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 110, height: 110)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(candidate.title)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                        Text(candidate.source == "commons" ? "Wikimedia Commons" : (candidate.summary ?? "Wikipedia"))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 130)
                                }
                                .buttonStyle(.plain)
                                .help(candidate.summary ?? candidate.title)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "Alternatives cancel"), action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 520)
        .onAppear(perform: search)
    }

    private func search() {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, !isSearching else { return }
        isSearching = true
        Task { @MainActor in
            candidates = await OverviewPictureStore.shared.alternatives(for: words)
            isSearching = false
            searched = true
        }
    }
}
