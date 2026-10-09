import SwiftUI
import UniformTypeIdentifiers

/// Decoded figure images by asset id — the base64 becomes a UIImage
/// once per asset, not once per render pass. NSCache empties itself
/// under memory pressure, which a phone actually meets.
private let figureImageCache = NSCache<NSString, UIImage>()

func decodedImage(for asset: LiquidDoc.Asset) -> UIImage? {
    if let hit = figureImageCache.object(forKey: asset.id as NSString) { return hit }
    guard let data = asset.data, let image = UIImage(data: data) else { return nil }
    figureImageCache.setObject(image, forKey: asset.id as NSString)
    return image
}

// The phone's reading end, based on the visionOS reader: the shelf as
// Articles and Journals, books arriving from Files or the community
// folder, and a reader with Scroll and Focus views, the Outline a
// pinch away — sized for a hand instead of a room. Keep in step with
// VisionOpeningView / VisionReaderView.

// MARK: - The shelf

struct ReadHomeView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var shelf: Shelf = .articles
    @State private var choosingEPUB = false
    @State private var choosingFolder = false
    @State private var showsSettings = false
    /// The Set Aside books stay tucked behind their header until asked.
    @State private var showsSetAside = false
    /// The file a failed Open EPUB… names, driving its alert.
    @State private var openFailedName: String?
    /// The Find field's words — narrowing Articles by title and author,
    /// Journals by name.
    @State private var searchText = ""

    private enum Shelf: Hashable { case articles, journals, lineage, guide }

    /// A book answers the Find field by its title or any of its authors.
    private func matchesSearch(_ record: EPUBRecord) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if record.title.localizedCaseInsensitiveContains(query) { return true }
        return record.authorList.contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if shelf == .guide {
                    PhoneGuideView()
                } else if shelf == .lineage {
                    PhoneLineageView()
                } else if model.epubRecords.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to Read Yet", systemImage: "books.vertical")
                    } description: {
                        Text("Open an EPUB from Files, or choose the iCloud folder your community shares — everything published from a Mac appears here.")
                    } actions: {
                        Button("Open EPUB…") { choosingEPUB = true }
                        Button("Choose Community Folder…") { choosingFolder = true }
                    }
                } else {
                    List {
                        switch shelf {
                        case .articles:
                            ForEach(model.alphabetical.filter(matchesSearch)) { record in
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
                        case .journals:
                            ForEach(model.venues.filter { venue in
                                searchText.isEmpty
                                    || venue.localizedCaseInsensitiveContains(searchText)
                            }, id: \.self) { venue in
                                NavigationLink {
                                    PhoneJournalView(venue: venue)
                                } label: {
                                    HStack {
                                        Label(venue, systemImage: "newspaper")
                                            .lineLimit(2)
                                        Spacer()
                                        Text("\(model.records(inVenue: venue).count)")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        case .lineage, .guide:
                            EmptyView()
                        }
                    }
                    .listStyle(.plain)
                }
            }
            // No title — the shelf's lists speak for themselves; the
            // top holds only the Articles/Journals choice, and the gear
            // keeps the bottom, centred on a bar of its own.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Showing", selection: $shelf) {
                        Text("Articles").tag(Shelf.articles)
                        Text("Journals").tag(Shelf.journals)
                        // Lineage sits out for now — the view keeps
                        // compiling; restore the tag to bring it back.
                        Text("Guide").tag(Shelf.guide)
                    }
                    .pickerStyle(.segmented)
                }
            }
            // The shelf's foot: the gear on the left, the Find field
            // beside it — titles, authors and journal names narrow as
            // the words are typed.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 10) {
                    Menu {
                        Button("Open EPUB…") { choosingEPUB = true }
                        Button(model.folderURL == nil
                               ? "Choose Community Folder…"
                               : "Change Community Folder…") { choosingFolder = true }
                        Divider()
                        Button("Settings…") { showsSettings = true }
                    } label: {
                        Image(systemName: "gear")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Settings and Open")
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Find", text: $searchText)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .navigationDestination(item: $model.readerRecordID) { recordID in
                PhoneReaderView(docID: recordID)
            }
        }
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
                    // A failed open must say so — a silent no-op reads
                    // as a dead button.
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
        // The maps' beat, here on the shelf: while the app is up, adopt
        // the shared standing every few seconds, so a Pin or Set Aside
        // made on the Mac or the headset arrives live — not only on the
        // next foreground scan. The read nudges a stale iCloud copy;
        // the fresh file lands on a following beat.
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
        // The app's first page, once: the Introduction.
        .task { model.openIntroductionOnFirstLaunch() }
    }

}

/// One shelf row, shared by the Articles list and the journal pages:
/// title and author, the pin's mark when it leads the pile, and the
/// pile verbs three ways — swipe right to pin, swipe left to set
/// aside, or hold for the menu. The Mac's EPUBPileMenu is the sibling.
struct PhoneShelfRow: View {
    @Environment(PhoneModel.self) private var model
    let record: EPUBRecord
    /// Set, the row pushes its reader from where it stands (a journal's
    /// list), so Back returns there — not to the shelf's top. Nil, the
    /// row uses the shelf's own destination at the stack's root.
    var opensLocally: Binding<String?>? = nil
    /// The title stands bold — the iPad Inbox's mark of a book not yet
    /// opened, as on the Mac.
    var emphasised = false
    /// The whole-document note being written or rewritten.
    @State private var editingNote = false
    @State private var noteDraft = ""

    var body: some View {
        Button {
            if let opensLocally {
                opensLocally.wrappedValue = record.id
            } else {
                model.readerRecordID = record.id
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.isToRead(record) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                        .accessibilityLabel("To Read")
                }
                if model.isTopOfPile(record) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .fontWeight(emphasised ? .bold : .regular)
                        .lineLimit(2)
                    Text(record.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // The reader's whole-document note, quiet lines
                    // under the author — as on the Mac's shelf rows.
                    if let note = model.documentNote(forAddress: record.id)?.body?.value {
                        Text(note)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The line under a row starts at the row's edge, whether or not a
        // bookmark or pin stands before its title.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleTopOfPile(record)
            } label: {
                Label(model.isTopOfPile(record) ? "Unpin" : "Pin",
                      systemImage: model.isTopOfPile(record) ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if model.isSetAside(record) {
                Button {
                    model.bringBack(record)
                } label: {
                    Label("Bring Back", systemImage: "arrow.uturn.backward")
                }
                .tint(.indigo)
            } else {
                Button {
                    model.setAside(record)
                } label: {
                    Label("Set Aside", systemImage: "moon.zzz")
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            if model.isToRead(record) {
                Button("Remove from To Read", systemImage: "bookmark.slash") {
                    model.removeFromToRead(id: record.id)
                }
            } else {
                Button("To Read", systemImage: "bookmark") {
                    model.markToRead(id: record.id, at: nil, quote: nil)
                }
            }
            Toggle("Pin", isOn: Binding(
                get: { model.isTopOfPile(record) },
                set: { _ in model.toggleTopOfPile(record) }))
            if model.isSetAside(record) {
                Button("Bring Back") { model.bringBack(record) }
            } else {
                Button("Set Aside") { model.setAside(record) }
            }
            Divider()
            // A note on the book itself — no words selected, none
            // needed: the one "describing" annotation the Mac's shelf
            // shows under the row.
            Button(model.documentNote(forAddress: record.id) == nil
                   ? "Note\u{2026}" : "Edit Note\u{2026}") {
                noteDraft = model.documentNote(forAddress: record.id)?.body?.value ?? ""
                editingNote = true
            }
        }
        .sheet(isPresented: $editingNote) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(record.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    TextEditor(text: $noteDraft)
                        .font(.body)
                }
                .padding()
                .navigationTitle("Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingNote = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        // Save with emptied text removes the note.
                        Button("Save") {
                            model.setDocumentNote(noteDraft, forAddress: record.id)
                            editingNote = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

// MARK: - One journal

/// One venue's papers, the whole list — tap a paper and it opens in
/// the reader, as on the headset.
struct PhoneJournalView: View {
    @Environment(PhoneModel.self) private var model
    let venue: String
    /// The journal's own reader push: Back from the paper returns to
    /// this list, not the shelf's top (the root destination would pop
    /// the journal on its way in).
    @State private var readerID: String?
    /// The venue's two faces: its articles listed, or laid out on the
    /// flat map (the Vision Pro's hallway plane, shared X and Y).
    @State private var showsMap = false

    var body: some View {
        VStack(spacing: 0) {
            if showsMap {
                // The Map fills the room alone — its way back rides on
                // the map itself, not a tab row above it.
                ProceedingsMapView(
                    items: mapItems,
                    folder: model.folderURL,
                    open: { readerID = $0 },
                    togglePin: { id in
                        if let record = record(id) { model.toggleTopOfPile(record) }
                    },
                    toggleSetAside: { id in
                        guard let record = record(id) else { return }
                        if model.isSetAside(record) {
                            model.bringBack(record)
                        } else {
                            model.setAside(record)
                        }
                    },
                    back: { showsMap = false },
                    tick: { model.adoptSharedStanding() })
            } else {
                Picker("View", selection: $showsMap) {
                    Text("Articles").tag(false)
                    Text("Map").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                List(model.records(inVenue: venue)) { record in
                    PhoneShelfRow(record: record, opensLocally: $readerID)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(venue)
        .navigationBarTitleDisplayMode(.inline)
        // The Map fills the screen; its foot bar carries the way back,
        // so the navigation bar withdraws with the tabs.
        .toolbar(showsMap ? .hidden : .visible, for: .navigationBar)
        .navigationDestination(item: $readerID) { recordID in
            PhoneReaderView(docID: recordID)
        }
    }

    /// The map shows the Set Aside books too, faded, rather than hiding
    /// them behind the list's pill.
    private var mapItems: [ProceedingsMapView.Item] {
        model.records(inVenue: venue).map {
            .init(id: $0.id, key: $0.folder, title: $0.title,
                  author: $0.author, isPinned: model.isTopOfPile($0))
        } + model.setAsideRecords(inVenue: venue).map {
            .init(id: $0.id, key: $0.folder, title: $0.title,
                  author: $0.author, isSetAside: true)
        }
    }

    private func record(_ id: String) -> EPUBRecord? {
        (model.records(inVenue: venue) + model.setAsideRecords(inVenue: venue))
            .first { $0.id == id }
    }
}

// MARK: - The reading theme

/// The reading's dress — ReadingDeskTheme's phone twin (that type
/// lives in a visionOS-only file): the same two themes, the same
/// "readingDeskTheme" key, so the choice travels. Keep in step.
enum PhoneReadingTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var displayName: String { self == .light ? "Light" : "Dark" }
    var scheme: ColorScheme { self == .light ? .light : .dark }

    /// The page behind the words — warm paper, or a quiet near-black.
    var page: Color {
        self == .light
            ? Color(red: 0.98, green: 0.97, blue: 0.94)
            : Color(red: 0.11, green: 0.11, blue: 0.12)
    }
}

// MARK: - Settings

/// The phone's reading settings — the Mac's pane, sized down. How
/// citations read applies live to whatever is open; the citation's
/// tap, and the source it reveals, are the same in every style. One
/// key across platforms: "origamiCitationStyle".
struct PhoneSettingsView: View {
    @AppStorage("origamiCitationStyle")
    private var citationStyleRaw = OrigamiCitationStyle.authorDate.rawValue
    /// How note marks read — the Mac's rule travels: a raised number
    /// must mean exactly one thing, never citations and notes at once.
    @AppStorage(ReaderNoteStyle.defaultsKey)
    private var noteStyleRaw = ReaderNoteStyle.superscript.rawValue
    /// Who the reader is — the Mac's Settings ▸ Author key: it names the
    /// iPad's own-papers row and signs highlights and notes.
    @AppStorage("authorName") private var authorName = ""
    /// What shows while a book is still arriving.
    @AppStorage(LoadingStyle.defaultsKey) private var loadingStyleRaw = LoadingStyle.animation.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name, as your papers carry it", text: $authorName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Your Name")
                } footer: {
                    Text("Signs your highlights and notes, and finds the papers you wrote.")
                }
                Section {
                    Picker("Citations", selection: $citationStyleRaw) {
                        ForEach(OrigamiCitationStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Citations")
                } footer: {
                    Text(OrigamiCitationStyle(rawValue: citationStyleRaw)?.blurb ?? "")
                }
                Section {
                    Picker("Endnotes & Footnotes", selection: $noteStyleRaw) {
                        ForEach(ReaderNoteStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Endnotes & Footnotes")
                } footer: {
                    Text("How note marks read: the raised number the paper prints (the default), bracketed, a quiet ‡, or the [] fold. A raised number must mean exactly one thing, so choosing Superscript for one moves the other off it.")
                }
                Section {
                    Picker("On Loading", selection: $loadingStyleRaw) {
                        ForEach(LoadingStyle.allCases) { style in
                            Text(style.displayName).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("On Loading")
                } footer: {
                    Text("While a book arrives — some seconds over a slow network — a plain spinner, or its title, author and date floating in space, to touch and to shake.")
                }
                .onChange(of: citationStyleRaw) {
                    if citationStyleRaw == OrigamiCitationStyle.superscript.rawValue,
                       noteStyleRaw == ReaderNoteStyle.superscript.rawValue {
                        noteStyleRaw = ReaderNoteStyle.bracketed.rawValue
                    }
                }
                .onChange(of: noteStyleRaw) {
                    if noteStyleRaw == ReaderNoteStyle.superscript.rawValue,
                       citationStyleRaw == OrigamiCitationStyle.superscript.rawValue {
                        citationStyleRaw = OrigamiCitationStyle.numeric.rawValue
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - The reader

struct PhoneReaderView: View {
    @Environment(PhoneModel.self) private var model
    let docID: String
    /// Opened over another book, from a citation: the way back leads to
    /// that book, not to the documents, so it stays a chevron.
    var opensOverBook = false

    /// The Mac's reading views, sized for the hand: Scroll (one clean
    /// column) and Focus — and on iPad, Horizontal, the sections side
    /// by side — with the Outline a pinch away. A persisted "faithful"
    /// from earlier builds decodes to nil and lands on Scroll.
    private enum Mode: String, CaseIterable {
        case scroll, horizontal, focus, outline
        var word: String {
            switch self {
            case .scroll: "Scroll"
            case .horizontal: "Horizontal"
            case .focus: "Focus"
            case .outline: "Outline"
            }
        }
    }

    /// Horizontal needs a table's width; the phone reads in one column.
    private var offersHorizontal: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    @AppStorage("phoneReaderMode") private var modeRaw = Mode.scroll.rawValue
    @AppStorage("phoneReaderFontDelta") private var fontDelta = 0.0
    /// The reading's appearance — the headset's Reading Desk choice, same key.
    @AppStorage("readingDeskTheme") private var themeRaw = PhoneReadingTheme.light.rawValue
    /// The colour theme — the Mac's full set, same "readerTheme" key:
    /// sepia to Solarized, the dyslexia and Irlen palettes among them.
    @AppStorage("readerTheme") private var readerThemeRaw = ReaderTheme.highContrast.rawValue
    /// Bionic Reading — the first half of every word bold, same key as
    /// the Mac's toggle.
    @AppStorage("bionicReading") private var bionicReading = false
    /// The Word assist's pace.
    @AppStorage("rsvpWPM") private var rsvpWPM = 250.0
    /// How citations read — the cross-platform choice (Settings ▸
    /// Citations), the same key the Mac and the headset honour.
    @AppStorage("origamiCitationStyle")
    private var citationStyleRaw = OrigamiCitationStyle.authorDate.rawValue
    @State private var focusIndex = 0
    @State private var expanded: Set<String> = []
    /// Pinch in and the reading folds into its outline; pinch out and it
    /// opens again — at the same spot, because the reading stays alive
    /// under the outline overlay. This remembers which view to return to.
    @State private var outlineReturnRaw = Mode.scroll.rawValue
    /// A heading tapped in the outline: the return lands there instead.
    @State private var outlineJumpID: String?
    /// The scroll view's pending jump (consumed by ScrollViewReader).
    @State private var scrollJumpID: String?
    /// The tapped citation's reference key, card-presented; the tapped
    /// dagger's endnote id likewise — the Mac's interactions, here.
    @State private var citationKey: String?
    /// An in-document jump to a figure: the image card, as a citation
    /// shows its source.
    @State private var jumpFigureID: String?
    /// The inline notes standing open — [] folded, the words in place
    /// when open, exactly the Mac's stretchtext manner.
    @State private var openInlineNotes: Set<String> = []
    @State private var noteID: String?
    /// The selection a Note… is being written for, and its words.
    @State private var noteTarget: SelectionNoteTarget?
    @State private var noteDraft = ""
    /// The vertical selection menu: the words, their paragraph, and
    /// where on screen they stand.
    @State private var selectionMenu: SelectionMenuState?
    /// Bumped when the menu closes, so the paragraph drops its grey
    /// selection — acted on or not, the words stand clean again.
    @State private var selectionClearToken = 0
    /// The words being sought — Find paints every occurrence and the
    /// Outline narrows to the sections that answer.
    @State private var findQuery: String?
    /// A cited document on the shelf, opened over this one from its
    /// citation card (or an origamitext:// link).
    @State private var linkedDocID: String?
    /// Whether the bottom bars are showing; they fade after four quiet
    /// seconds. `barsWake` restarts the count.
    @State private var barsShown = true
    @State private var barsWake = 0
    /// The brief word a To Read press answers with ("To Read", or
    /// "Removed from To Read"); nil when nothing is showing.
    @State private var toReadNotice: String?
    /// Whether this opening has already gone to the To Read place — once
    /// per opening, so reading on is never pulled back.
    @State private var landedAtToRead = false

    private struct SelectionMenuState {
        let paragraph: LiquidDoc.Paragraph
        let doc: LiquidDoc
        let selected: String
        let prefix: String?
        let suffix: String?
        let anchor: CGRect   // window coordinates
    }
    /// Focus's assists — the Mac's: one sentence, one paragraph, or one
    /// word (RSVP) at a time.
    /// Focus's units: the section — a heading and what it heads — then
    /// its sentences, or its paragraphs.
    private enum Assist: String { case section, sentence, paragraph }
    @State private var assistRaw = Assist.section.rawValue
    @State private var sentenceIndex = 0
    @State private var paragraphIndex = 0
    @State private var showsRSVP = false
    @State private var rsvpWords: [String] = []
    @State private var rsvpWordIndex = 0
    @State private var rsvpPlaying = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var mode: Mode {
        let chosen = Mode(rawValue: modeRaw) ?? .scroll
        // A Horizontal persisted on an iPad never cramps an iPhone.
        if chosen == .horizontal, !offersHorizontal { return .scroll }
        return chosen
    }
    private var outlineReturnMode: Mode { Mode(rawValue: outlineReturnRaw) ?? .scroll }
    /// The window's top safe-area inset — the notch band's height on
    /// iPhone; 0 on flat-topped screens.
    private var notchInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }
    private var theme: PhoneReadingTheme {
        PhoneReadingTheme(rawValue: themeRaw) ?? .light
    }
    private var readerTheme: ReaderTheme {
        ReaderTheme(rawValue: readerThemeRaw) ?? .highContrast
    }
    private var assist: Assist { Assist(rawValue: assistRaw) ?? .section }
    /// The page behind the words: the colour theme's, else plain by
    /// appearance; and the ink the theme asks for, else the scheme's.
    private var pageColor: Color {
        readerTheme.background(for: readingScheme)
            ?? (readingScheme == .dark ? .black : .white)
    }
    private var inkStyle: AnyShapeStyle {
        readerTheme.textColor(for: readingScheme).map(AnyShapeStyle.init)
            ?? AnyShapeStyle(.primary)
    }
    /// Everything that colours ink — the environment AND the attributed
    /// text, whose colours are baked at build time — reads this, never
    /// the raw colorScheme (the visionOS lesson).
    private var readingScheme: ColorScheme { theme.scheme }
    private var citationStyle: OrigamiCitationStyle {
        OrigamiCitationStyle(rawValue: citationStyleRaw) ?? .authorDate
    }
    private var bodySize: CGFloat { 17 + fontDelta }

    /// Settings ▸ On Loading.
    @AppStorage(LoadingStyle.defaultsKey) private var loadingStyleRaw = LoadingStyle.animation.rawValue
    private var loadingStyle: LoadingStyle { LoadingStyle(rawValue: loadingStyleRaw) ?? .animation }

    /// "8 October 2026" from the record's ISO date, or its year alone.
    private static func loadingDate(_ iso: String?) -> String? {
        guard let iso, iso.count >= 4 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        if iso.count >= 10, let date = parser.date(from: String(iso.prefix(10))) {
            return date.formatted(.dateTime.day().month(.wide).year())
        }
        return String(iso.prefix(4))
    }

    var body: some View {
        Group {
            if let doc = model.index.byID[docID]?.doc {
                reading(doc)
            } else {
                // The book is still arriving — over a slow network, for
                // some seconds. Its title page floats in space meanwhile,
                // to touch and shake; no bars until there is a page for
                // them to work on.
                if loadingStyle == .animation,
                   let record = model.epubRecords.first(where: { $0.id == docID }) {
                    LoadingTitleView(title: record.title,
                                     author: (record.authors ?? [record.author]).joined(separator: ", "),
                                     date: Self.loadingDate(record.dateISO))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Reading takes the whole screen: the top stays clean — no back
        // button, no bar, and no clock — the way a page should. The way
        // back is the chevron in the foot bar.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        // On iPhone the sensor housing sits in a black band of its own,
        // matching the foot bar — the page never flows around the notch.
        // iPad's top is flat and stays bare.
        .overlay(alignment: .top) {
            if UIDevice.current.userInterfaceIdiom == .phone, notchInset > 0 {
                Color.black
                    .frame(maxWidth: .infinity)
                    .frame(height: notchInset)
                    .offset(y: -notchInset)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.index.byID[docID]?.doc != nil {
                VStack(spacing: 0) {
                    if mode == .focus, !showsRSVP { assistBar }
                    footBar
                }
                // After four quiet seconds the bars fade from the page;
                // their place stays, and a tap there brings them back.
                .opacity(barsShown ? 1 : 0)
                .allowsHitTesting(barsShown)
                .simultaneousGesture(TapGesture().onEnded { showBars() })
                .overlay {
                    if !barsShown {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showBars() }
                            .accessibilityElement()
                            .accessibilityLabel("Show the toolbar")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .task(id: barsWake) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, !UIAccessibility.isVoiceOverRunning else { return }
                    withAnimation(.easeOut(duration: 0.6)) { barsShown = false }
                }
            }
        }
        .onChange(of: modeRaw) { showBars() }
        .onChange(of: assistRaw) { showBars() }
        // A citation's tap opens the source's card, a dagger's its
        // endnote — never the browser. Anything else opens normally.
        .environment(\.openURL, OpenURLAction { url in
            if let key = OrigamiReading.citationKey(from: url) {
                citationKey = key
                return .handled
            }
            if let id = OrigamiReading.noteID(from: url) {
                noteID = id
                return .handled
            }
            if let inlineID = OrigamiReading.inlineNoteID(from: url) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if openInlineNotes.contains(inlineID) {
                        openInlineNotes.remove(inlineID)
                    } else {
                        openInlineNotes.insert(inlineID)
                    }
                }
                return .handled
            }
            if followJump(url) { return .handled }
            // A link to a document on the shelf opens it here; one that
            // is not here has nowhere to go, rather than the system.
            if url.scheme?.lowercased() == "origamitext" {
                if let recordID = shelfRecordID(forOrigamiLink: url) { linkedDocID = recordID }
                return .handled
            }
            return .systemAction
        })
        .sheet(item: Binding(
            get: { citationKey.map { TappedCitation(key: $0) } },
            set: { citationKey = $0?.key })) { tapped in
            if let doc = model.index.byID[docID]?.doc {
                PhoneCitationCard(doc: doc, key: tapped.key,
                                  openOnShelf: { linkedDocID = $0 })
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(item: $noteTarget) { target in
            NavigationStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\u{201C}\(target.selection.text)\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    TextEditor(text: $noteDraft)
                        .font(.body)
                }
                .padding()
                .navigationTitle("Note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { noteTarget = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.addComment(noteDraft, on: target.selection)
                            noteTarget = nil
                        }
                        .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: Binding(
            get: { noteID.map { TappedNote(id: $0) } },
            set: { noteID = $0?.id })) { tapped in
            if let doc = model.index.byID[docID]?.doc {
                PhoneEndnoteCard(doc: doc, noteID: tapped.id,
                                 style: citationStyle)
                    .presentationDetents([.medium])
            }
        }
        .sheet(item: Binding(
            get: { jumpFigureID.map { TappedFigure(id: $0) } },
            set: { jumpFigureID = $0?.id })) { tapped in
            if let doc = model.index.byID[docID]?.doc {
                PhoneFigureCard(doc: doc, paragraphID: tapped.id)
                    .presentationDetents([.medium, .large])
            }
        }
        // Opening a book takes it out of the Inbox's bold, and tells the
        // iPad's split view to give the page the whole screen.
        .onAppear {
            model.markOpened(id: docID)
            model.openReaders += 1
        }
        .onDisappear { model.openReaders -= 1 }
        // A cited book on the shelf opens over this one; the foot bar's
        // chevron comes back here, to the citing page.
        .navigationDestination(item: $linkedDocID) { recordID in
            PhoneReaderView(docID: recordID, opensOverBook: true)
        }
    }

    /// The shelf book an origamitext://open/<address> link names — by
    /// record id or by its shelf folder — or nil when it is not here.
    private func shelfRecordID(forOrigamiLink url: URL) -> String? {
        guard url.scheme?.lowercased() == "origamitext" else { return nil }
        let address = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !address.isEmpty else { return nil }
        return model.epubRecords.first { $0.id == address || $0.folder == address }?.id
    }

    private struct TappedCitation: Identifiable {
        let key: String
        var id: String { key }
    }

    private struct TappedNote: Identifiable {
        let id: String
    }

    private struct TappedFigure: Identifiable {
        let id: String
    }

    /// An in-document jump (a \ref made live at import): a figure
    /// shows itself in place — the whole point is seeing the image
    /// BEFORE reading further — and anything else scrolls the reading
    /// to the target paragraph.
    private func followJump(_ url: URL) -> Bool {
        guard url.scheme == "origami-jump" else { return false }
        let target = String(url.absoluteString.dropFirst("origami-jump:".count))
        guard let doc = model.index.byID[docID]?.doc else { return true }
        if let paragraph = (doc.body ?? []).first(where: { $0.id == target }),
           LiquidDoc.imageReference(in: paragraph.text) != nil {
            jumpFigureID = target
            return true
        }
        // The landing is the target's SECTION — the id the readings
        // register. Horizontal's paragraphs live inside nested column
        // scrolls the outer proxy cannot reach, lazy stacks register
        // no unrealized ids, and Focus shows one section at a time —
        // so a bare paragraph id would land nowhere at all.
        let sections = OrigamiSection.build(from: doc)
        guard let index = sections.firstIndex(where: { section in
            section.heading?.id == target
                || section.paragraphs.contains { $0.id == target }
        }) else {
            scrollJumpID = target
            return true
        }
        if mode == .focus {
            // The section appears at once, as a turned page does.
            withTransaction(Transaction(animation: nil)) { focusIndex = index }
        } else {
            scrollJumpID = sections[index].id
        }
        return true
    }

    @ViewBuilder private func reading(_ doc: LiquidDoc) -> some View {
        let sections = OrigamiSection.build(from: doc)
        // The outline never replaces the reading — it lays over it, so
        // pinching back out lands on the very spot the reading held.
        let contentMode = mode == .outline ? outlineReturnMode : mode
        Group {
            switch contentMode {
            case .scroll, .outline:
                scrollBody(sections, doc: doc)
            case .horizontal:
                horizontalBody(sections, doc: doc)
            case .focus:
                focusBody(sections, doc: doc)
            }
        }
        // Links and citations wear the body's ink, never link-blue —
        // a tap answers with a card, so the words need no costume.
        .tint(inkStyle)
        // Pinch in: the reading folds into its outline.
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            guard mode != .outline, value.magnification < 0.75 else { return }
            enterOutline()
        })
        // The readings stand on the theme's page, its scheme riding along.
        .background { pageColor.ignoresSafeArea() }
        .task { landAtToRead(doc) }
        .overlay(alignment: .top) {
            if toReadNotice != nil {
                toReadNoticeView.padding(.top, 24)
            }
        }
        .overlay {
            if mode == .outline {
                outlineBody(sections, doc: doc)
                    .scrollContentBackground(.hidden)
                    .background(pageColor.ignoresSafeArea())
                    .environment(\.colorScheme, readingScheme)
                    // Pinch out: the outline opens back into the reading.
                    .simultaneousGesture(MagnifyGesture().onEnded { value in
                        guard value.magnification > 1.3 else { return }
                        leaveOutline(sections)
                    })
            }
        }
        .overlay {
            if showsRSVP { rsvpOverlay }
        }
        // The selection's own menu: vertical from the start — every verb
        // visible at once, where the system bar showed two and a ">".
        .overlay {
            if let menu = selectionMenu {
                SelectionMenuCard(
                    anchor: menu.anchor,
                    highlightsPresent: true,
                    onFind: {
                        closeSelectionMenu()
                        enterOutline()
                        findQuery = menu.selected.trimmingCharacters(in: .whitespaces)
                    },
                    onCopyCitation: {
                        closeSelectionMenu()
                        copySelectionCitation(menu.doc, paragraph: menu.paragraph,
                                              selected: menu.selected)
                    },
                    isToRead: model.toReadItem(id: docID) != nil,
                    onToRead: {
                        closeSelectionMenu()
                        toggleToRead(at: menu.paragraph)
                    },
                    onHighlight: { kind in
                        closeSelectionMenu()
                        model.addTag(kind, on: PhoneModel.ReaderSelection(
                            address: docID, paragraphID: menu.paragraph.id,
                            text: menu.selected, prefix: menu.prefix, suffix: menu.suffix))
                    },
                    onRemoveHighlights: {
                        closeSelectionMenu()
                        removeHighlights(doc: menu.doc, paragraph: menu.paragraph,
                                         selected: menu.selected)
                    },
                    onNote: {
                        closeSelectionMenu()
                        noteDraft = ""
                        noteTarget = SelectionNoteTarget(selection: PhoneModel.ReaderSelection(
                            address: docID, paragraphID: menu.paragraph.id,
                            text: menu.selected, prefix: menu.prefix, suffix: menu.suffix))
                    },
                    onCopy: {
                        closeSelectionMenu()
                        UIPasteboard.general.string = menu.selected
                    },
                    onDismiss: { closeSelectionMenu() })
            }
        }
        .environment(\.colorScheme, readingScheme)
        .scrollContentBackground(.hidden)
    }

    /// Puts the selection menu away and drops the grey selection with it.
    private func closeSelectionMenu() {
        selectionMenu = nil
        selectionClearToken += 1
    }

    /// Fold into the outline, remembering the view to come back to.
    /// A fresh fold starts clean; Find sets its words right after.
    private func enterOutline() {
        guard mode != .outline else { return }
        outlineReturnRaw = mode.rawValue
        outlineJumpID = nil
        findQuery = nil
        expanded = []
        showsRSVP = false
        withAnimation { modeRaw = Mode.outline.rawValue }
    }

    /// Open back out of the outline: to the very spot the reading held,
    /// or — when a heading was tapped — to that heading's section.
    private func leaveOutline(_ sections: [OrigamiSection]) {
        let jump = outlineJumpID
        outlineJumpID = nil
        withAnimation { modeRaw = outlineReturnRaw }
        guard let jump else { return }
        switch outlineReturnMode {
        case .focus:
            // The jump may name a section or one of its paragraphs.
            if let index = sections.firstIndex(where: { section in
                section.id == jump || section.paragraphs.contains { $0.id == jump }
            }) {
                focusIndex = index
                sentenceIndex = 0
                paragraphIndex = 0
            }
        case .scroll:
            scrollJumpID = jump
        case .horizontal:
            // The jump names a section or a paragraph within one; the
            // spread scrolls its column into view.
            scrollJumpID = sections.first { section in
                section.id == jump || section.paragraphs.contains { $0.id == jump }
            }?.id ?? jump
        case .outline:
            break
        }
    }

    // MARK: Scroll

    private func scrollBody(_ sections: [OrigamiSection], doc: LiquidDoc) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        sectionView(section, doc: doc)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                // A readable measure on wide screens: the column holds a
                // book's width, centred. Phones are narrower than the cap.
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            // A heading tapped in the outline lands here.
            .onChange(of: scrollJumpID) {
                guard let id = scrollJumpID else { return }
                scrollJumpID = nil
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    // MARK: Horizontal — the sections side by side (iPad)

    private func horizontalBody(_ sections: [OrigamiSection], doc: LiquidDoc) -> some View {
        // The columns fit the page: two in portrait, three in
        // landscape, sized to the width they share — and a swipe steps
        // one column along, never a loose glide (view-aligned snapping,
        // limited to a single step per gesture).
        // A heading with nothing under it but another heading shares
        // that heading's column — a lone title never spends a column.
        let groups = Self.horizontalColumns(sections)
        return GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let columns = CGFloat(landscape ? 3 : 2)
            let spacing: CGFloat = 28
            let sidePadding: CGFloat = 24
            let columnWidth = max(
                220,
                (geometry.size.width - sidePadding * 2 - spacing * (columns - 1)) / columns)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: spacing) {
                        ForEach(groups, id: \.first?.id) { group in
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(group) { section in
                                        sectionView(section, doc: doc)
                                    }
                                }
                                .padding(.vertical, 16)
                            }
                            .frame(width: columnWidth, height: geometry.size.height)
                            .id(group.first?.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, sidePadding)
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                // A heading tapped in the outline (or a jump link) lands
                // on the column that HOLDS its section — which may be a
                // merged group under an earlier heading.
                .onChange(of: scrollJumpID) {
                    guard let id = scrollJumpID else { return }
                    scrollJumpID = nil
                    let target = groups.first { group in
                        group.contains { section in
                            section.id == id || section.heading?.id == id
                                || section.paragraphs.contains { $0.id == id }
                        }
                    }?.first?.id ?? id
                    withAnimation { proxy.scrollTo(target, anchor: .leading) }
                }
            }
        }
    }

    /// The Horizontal columns: sections in order, each column ending
    /// with the first section that carries words — heading-only
    /// sections ride with the section that follows them.
    static func horizontalColumns(_ sections: [OrigamiSection]) -> [[OrigamiSection]] {
        var groups: [[OrigamiSection]] = []
        var pending: [OrigamiSection] = []
        for section in sections {
            pending.append(section)
            if !section.paragraphs.isEmpty {
                groups.append(pending)
                pending = []
            }
        }
        if !pending.isEmpty { groups.append(pending) }
        return groups
    }

    @ViewBuilder private func sectionView(_ section: OrigamiSection,
                                          doc: LiquidDoc) -> some View {
        if let heading = section.heading {
            Text(OrigamiReading.inlineAttributed(heading.text, in: doc,
                                                 citations: citationStyle,
                                                 appearance: readingScheme))
                .font(.system(size: bodySize + CGFloat(max(0, 4 - section.level) * 2),
                              weight: .semibold, design: .serif))
                .foregroundStyle(inkStyle)
                .id(heading.id)
                .padding(.top, 8)
                .modifier(ToReadPress { toggleToRead(at: heading) })
        }
        ForEach(section.paragraphs) { paragraph in
            paragraphView(paragraph, doc: doc)
                .id(paragraph.id)
                .modifier(ToReadPress { toggleToRead(at: paragraph) })
        }
    }

    /// Brings the bars back and starts their four seconds again.
    private func showBars() {
        withAnimation(.easeOut(duration: 0.2)) { barsShown = true }
        barsWake += 1
    }

    // MARK: To Read

    /// The press: To Read at this paragraph, or — when the book is already
    /// To Read — off again. A haptic and a brief word answer it.
    private func toggleToRead(at paragraph: LiquidDoc.Paragraph) {
        if model.toReadItem(id: docID) != nil {
            model.removeFromToRead(id: docID)
            showToReadNotice("Removed from To Read")
        } else {
            model.markToRead(id: docID, at: paragraph.id,
                             quote: paragraph.text)
            showToReadNotice("To Read")
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func showToReadNotice(_ words: String) {
        withAnimation(.easeOut(duration: 0.2)) { toReadNotice = words }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if toReadNotice == words {
                withAnimation(.easeIn(duration: 0.3)) { toReadNotice = nil }
            }
        }
    }

    private var toReadNoticeView: some View {
        Label(toReadNotice ?? "", systemImage: toReadNotice == "To Read" ? "bookmark.fill" : "bookmark.slash")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .allowsHitTesting(false)
    }

    /// Opening a To Read book goes to the marked paragraph — found by its
    /// id, else by its opening words — on whatever device marked it.
    private func landAtToRead(_ doc: LiquidDoc) {
        guard !landedAtToRead else { return }
        landedAtToRead = true
        guard let item = model.toReadItem(id: docID) else { return }
        let body = doc.body ?? []
        var target = body.first { $0.id == item.at }?.id
        if target == nil, let quote = item.quote, quote.count >= 12 {
            let opening = String(quote.prefix(40))
            target = body.first { $0.text.contains(opening) }?.id
        }
        guard let target else { return }
        let sections = OrigamiSection.build(from: doc)
        guard let index = sections.firstIndex(where: { section in
            section.heading?.id == target || section.paragraphs.contains { $0.id == target }
        }) else { return }
        if mode == .focus {
            withTransaction(Transaction(animation: nil)) { focusIndex = index }
        } else {
            // The section first — a lazy stack has not built the
            // paragraph yet — then the paragraph itself once it has.
            scrollJumpID = sections[index].id
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                scrollJumpID = target
            }
        }
    }

    @ViewBuilder private func paragraphView(_ paragraph: LiquidDoc.Paragraph,
                                            doc: LiquidDoc) -> some View {
        if paragraph.text == "---" {
            Divider()
        } else if let reference = LiquidDoc.imageReference(in: paragraph.text) {
            // A figure: the image with its printed caption beneath — a
            // double-tap lifts it into the figure card, as the Mac's
            // double-click lifts it into a window.
            VStack(alignment: .leading, spacing: 6) {
                if let asset = doc.assets.first(where: { $0.id == reference.id }),
                   let image = decodedImage(for: asset), let url = asset.linkURL {
                    // A figure made from a view (ORIGAMI-FIGURE-LINKS-SPEC):
                    // a tap opens its link, untouched, outside the app;
                    // the double-tap keeps the figure card, and the long
                    // press offers Show Image and Show Reference.
                    let referenceKey = asset.citationKey
                        .flatMap { key in doc.references.contains { $0.id == key } ? key : nil }
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(alignment: .bottomTrailing) {
                            Text(asset.linkActionTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.62), in: Capsule())
                                .padding(8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 4))
                        .hoverEffect(.lift)
                        .onTapGesture(count: 2) { jumpFigureID = paragraph.id }
                        .onTapGesture { UIApplication.shared.open(url) }
                        .contextMenu {
                            Button(asset.linkActionTitle) { UIApplication.shared.open(url) }
                            Button("Show Image") { jumpFigureID = paragraph.id }
                            if let referenceKey {
                                Button("Show Reference") { citationKey = referenceKey }
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(asset.alt ?? asset.linkActionTitle)
                        .accessibilityHint(asset.linkAccessibilityHint)
                        .accessibilityAddTraits([.isLink, .isImage])
                        .accessibilityAction { UIApplication.shared.open(url) }
                    if let caption = asset.alt, !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let asset = doc.assets.first(where: { $0.id == reference.id }),
                   let image = decodedImage(for: asset) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 480)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture(count: 2) { jumpFigureID = paragraph.id }
                    if let caption = asset.alt, !caption.isEmpty {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !reference.alt.isEmpty {
                    // The words stand in when the pixels are absent.
                    Text(reference.alt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .id(paragraph.id)
        } else if let code = OrigamiReading.fencedCode(in: paragraph.text) {
            // A code block, as the page prints it: monospace in a quiet
            // box, whitespace exactly as written.
            Text(code)
                .font(.system(size: max(11, bodySize - 3), design: .monospaced))
                .foregroundStyle(inkStyle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .id(paragraph.id)
        } else {
            selectableText(paragraph.text, of: paragraph, doc: doc,
                           size: bodySize, lineSpacing: 4)
                .id(paragraph.id)
        }
    }

    /// Words the reader can select, with the selection card — Scroll's
    /// paragraphs, and Focus's one sentence or one paragraph alike. The
    /// selection belongs to `paragraph`, which a sentence is part of.
    private func selectableText(_ text: String, of paragraph: LiquidDoc.Paragraph,
                                doc: LiquidDoc, size: CGFloat,
                                lineSpacing: CGFloat) -> some View {
            PhoneSelectableParagraph(
                attributed: rendered(text, doc: doc, paragraphID: paragraph.id),
                baseSize: size,
                inkColor: inkUIColor,
                lineSpacing: lineSpacing,
                onLink: { url in
                    if let key = OrigamiReading.citationKey(from: url) {
                        citationKey = key
                        return true
                    }
                    if let id = OrigamiReading.noteID(from: url) {
                        noteID = id
                        return true
                    }
                    if let inlineID = OrigamiReading.inlineNoteID(from: url) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if openInlineNotes.contains(inlineID) {
                                openInlineNotes.remove(inlineID)
                            } else {
                                openInlineNotes.insert(inlineID)
                            }
                        }
                        return true
                    }
                    if followJump(url) { return true }
                    return false
                },
                onSelectionMenu: { selected, prefix, suffix, anchor in
                    selectionMenu = SelectionMenuState(
                        paragraph: paragraph, doc: doc, selected: selected,
                        prefix: prefix, suffix: suffix, anchor: anchor)
                },
                clearSelectionToken: selectionClearToken)
    }

    private struct SelectionNoteTarget: Identifiable {
        let id = UUID()
        let selection: PhoneModel.ReaderSelection
    }

    /// The theme's ink as UIKit sees it, for the selectable paragraphs.
    private var inkUIColor: UIColor? {
        readerTheme.textColor(for: readingScheme).map { UIColor($0) }
    }

    /// The Mac's citation clipboard, phone-sized: the private JSON for
    /// Author and Origami Text, the quoted words for everyone else.
    /// Cross-app contract: the type string matches CitationClipboard.
    private func copySelectionCitation(_ doc: LiquidDoc,
                                       paragraph: LiquidDoc.Paragraph,
                                       selected: String) {
        let record = model.epubRecords.first { $0.id == docID }
        let payload = OrigamiReading.authorCitationPayload(
            for: paragraph, in: doc, quote: selected,
            sourceFile: record?.originalFilename, doi: record?.doi)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let year = doc.date?.yearText
            ?? String(calendar.component(.year, from: doc.created))
        let citation = OrigamiCitation(
            to: doc.id, fragment: paragraph.id, rel: "cites",
            quotedText: payload.content,
            author: doc.displayAuthor, year: year,
            bibtex: payload.bibtex,
            documentTitle: doc.title,
            documentFilename: record?.originalFilename)
        var item: [String: Any] = [UTType.utf8PlainText.identifier: payload.content]
        if let data = try? JSONEncoder().encode(citation) {
            item["info.futuretextlab.origami-citation"] = data
        }
        UIPasteboard.general.items = [item]
    }


    /// Clears any highlight or judgment the selection touches — quotes
    /// and selection are compared as ranges over the rendered words,
    /// the same text they were captured from.
    private func removeHighlights(doc: LiquidDoc, paragraph: LiquidDoc.Paragraph,
                                  selected: String) {
        let plain = String(rendered(paragraph.text, doc: doc).characters)
        let selectedRange = plain.range(of: selected)
        model.removeAnnotations(inParagraph: paragraph.id, at: docID) { quote in
            if let selectedRange, let quoteRange = plain.range(of: quote) {
                return selectedRange.overlaps(quoteRange)
            }
            return quote.contains(selected) || selected.contains(quote)
        }
    }

    /// Paints the reader's annotations over the paragraph's words — the
    /// kind's colour behind the exact quote.
    private func painted(_ attributed: AttributedString,
                         paragraphID: String) -> AttributedString {
        _ = model.annotationsStamp   // repaint when the sidecar changes
        let annotations = model.annotations(forAddress: docID)
        guard !annotations.isEmpty else { return attributed }
        var out = attributed
        let plain = String(out.characters)
        for annotation in annotations {
            var fragment: String?
            var quote: String?
            for selector in annotation.target.selectors {
                switch selector {
                case .fragment(let value, _): fragment = fragment ?? value
                case .quote(let exact, _, _): quote = quote ?? exact
                default: break
                }
            }
            guard let quote else { continue }
            if let fragment, fragment != paragraphID { continue }
            guard let range = plain.range(of: quote),
                  let attrRange = Range(range, in: out) else { continue }
            let kind = ReaderAnnotationKind.kind(of: annotation) ?? .highlight
            out[attrRange].backgroundColor =
                PhoneAnnotationInk.color(of: kind).opacity(0.35)
        }
        return out
    }

    // MARK: Focus

    private func focusBody(_ sections: [OrigamiSection], doc: LiquidDoc) -> some View {
        let index = min(max(focusIndex, 0), max(sections.count - 1, 0))
        return VStack(spacing: 0) {
            if sections.isEmpty {
                ContentUnavailableView("Nothing to Read", systemImage: "doc.text")
            } else {
                switch assist {
                case .section:
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            sectionView(sections[index], doc: doc)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                    // A new section is a new page: it opens at its top,
                    // not at the last one's scroll, and is not morphed in.
                    .id(sections[index].id)
                    .transaction { $0.animation = nil }
                case .sentence:
                    let sentences = sentences(of: sections[index])
                    let at = min(max(sentenceIndex, 0), max(sentences.count - 1, 0))
                    // A sentence stands alone: no "5 of 22" beside it.
                    let sentence = sentences.isEmpty ? "" : sentences[at]
                    unitDisplay(sentence,
                                of: sections[index].paragraphs.first { $0.text.contains(sentence) }
                                    ?? sections[index].paragraphs.first,
                                doc: doc, place: nil)
                        .modifier(TapSides { step($0, sections: sections, index: index) })
                case .paragraph:
                    let paragraphs = sections[index].paragraphs
                    let at = min(max(paragraphIndex, 0), max(paragraphs.count - 1, 0))
                    unitDisplay(paragraphs.isEmpty ? "" : paragraphs[at].text,
                                of: paragraphs.isEmpty ? nil : paragraphs[at],
                                doc: doc, place: nil)
                        .modifier(TapSides { step($0, sections: sections, index: index) })
                }
                stepBar(sections, doc: doc, index: index)
                    // The ‹ title › bar fades with the toolbar, and a tap
                    // where it stood brings both back.
                    .opacity(barsShown ? 1 : 0)
                    .allowsHitTesting(barsShown)
                    .simultaneousGesture(TapGesture().onEnded { showBars() })
                    .overlay {
                        if !barsShown {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { showBars() }
                        }
                    }
            }
        }
    }

    /// One sentence or paragraph alone on the page, big enough to settle
    /// into — the Mac's assists, sized for the hand.
    private func unitDisplay(_ text: String, of paragraph: LiquidDoc.Paragraph?,
                             doc: LiquidDoc, place: String?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Group {
                if let paragraph {
                    // Selectable, with the card — Highlight, Note, To Read.
                    selectableText(text, of: paragraph, doc: doc,
                                   size: bodySize + 4, lineSpacing: 6)
                } else {
                    Text(rendered(text, doc: doc))
                        .font(.system(size: bodySize + 4, design: .serif))
                        .foregroundStyle(inkStyle)
                        .lineSpacing(6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Clear of the tap strips at each edge (a tenth of the width),
            // so pressing a line's last word never turns the page.
            .padding(.horizontal, 8)
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
            .frame(maxWidth: .infinity)
            if let place {
                Text(place)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Previous/Next step whatever Focus is showing: the section, its
    /// sentences, or its paragraphs — crossing into the next section at
    /// the edges.
    private func stepBar(_ sections: [OrigamiSection], doc: LiquidDoc, index: Int) -> some View {
        HStack {
            Button { step(-1, sections: sections, index: index) } label: {
                Label("Previous", systemImage: "chevron.left")
                    .foregroundStyle(Self.inactiveBarGrey)
            }
            Spacer()
            // The heading being read, so stepping is by the book's own
            // sections, named as its contents names them.
            VStack(spacing: 1) {
                Text(sections[index].title.replacingOccurrences(of: "*", with: ""))
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(Self.inactiveBarGrey)
                // Counts stay out of Sentence and Paragraph, whose point
                // is the one unit; the heading alone says where it stands.
                if assist == .section {
                    Text("\(index + 1) of \(sections.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { step(1, sections: sections, index: index) } label: {
                Label("Next", systemImage: "chevron.right")
                    .foregroundStyle(Self.inactiveBarGrey)
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// No animation: the next section, sentence or paragraph replaces
    /// the last at once, rather than rising into place.
    private func step(_ delta: Int, sections: [OrigamiSection], index: Int) {
        withTransaction(Transaction(animation: nil)) {
            switch assist {
            case .section:
                focusIndex = min(max(index + delta, 0), sections.count - 1)
            case .sentence:
                let count = sentences(of: sections[index]).count
                let next = sentenceIndex + delta
                if next < 0 || next >= count {
                    focusIndex = min(max(index + delta, 0), sections.count - 1)
                    sentenceIndex = 0
                } else {
                    sentenceIndex = next
                }
            case .paragraph:
                let count = sections[index].paragraphs.count
                let next = paragraphIndex + delta
                if next < 0 || next >= count {
                    focusIndex = min(max(index + delta, 0), sections.count - 1)
                    paragraphIndex = 0
                } else {
                    paragraphIndex = next
                }
            }
        }
    }

    private func sentences(of section: OrigamiSection) -> [String] {
        section.paragraphs.flatMap { OrigamiReading.sentences(of: $0.text) }
    }

    // MARK: Outline

    /// Whether a paragraph answers the sought words, on the rendered text.
    private func matchesFind(_ paragraph: LiquidDoc.Paragraph, doc: LiquidDoc) -> Bool {
        guard let query = findQuery?.trimmingCharacters(in: .whitespaces),
              !query.isEmpty else { return true }
        return model.renderedPlain(paragraph.id, in: doc.id) {
            String(rendered(paragraph.text, doc: doc).characters)
        }
        .localizedCaseInsensitiveContains(query)
    }

    private func outlineBody(_ sections: [OrigamiSection], doc: LiquidDoc) -> some View {
        let finding = findQuery?.trimmingCharacters(in: .whitespaces).isEmpty == false
        let shown = finding
            ? sections.filter { section in
                section.paragraphs.contains { matchesFind($0, doc: doc) }
            }
            : sections
        return List {
            if finding, let query = findQuery {
                // The Find header: what is sought, how many sections
                // answer, and the way out.
                HStack {
                    Label("\u{201C}\(query)\u{201D}", systemImage: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(shown.count) section\(shown.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button {
                        findQuery = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(shown) { section in
                DisclosureGroup(isExpanded: finding
                    ? .constant(true)
                    : Binding(
                        get: { expanded.contains(section.id) },
                        set: { open in
                            if open { expanded.insert(section.id) }
                            else { expanded.remove(section.id) }
                        })) {
                    ForEach(finding
                            ? section.paragraphs.filter { matchesFind($0, doc: doc) }
                            : section.paragraphs) { paragraph in
                        if finding {
                            // A found paragraph is a door: tap it and
                            // the reading opens right there.
                            Text(rendered(paragraph.text, doc: doc,
                                          paragraphID: paragraph.id))
                                .font(.system(size: bodySize, design: .serif))
                                .foregroundStyle(inkStyle)
                                .lineLimit(4)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    outlineJumpID = paragraph.id
                                    leaveOutline(sections)
                                }
                                .listRowSeparator(.hidden)
                        } else {
                            paragraphView(paragraph, doc: doc)
                                .listRowSeparator(.hidden)
                        }
                    }
                } label: {
                    // The title is a door: tap it and the reading opens
                    // at this section. The chevron alone discloses the
                    // section's words in place.
                    Text(section.title)
                        .font(.system(size: bodySize, weight: .semibold, design: .serif))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            outlineJumpID = section.id
                            leaveOutline(sections)
                        }
                }
            }
        }
        .listStyle(.plain)
    }

    /// The paragraph's attributed text: tokens resolved, the theme's
    /// appearance, and — when asked — the bionic bolding. Memoized on
    /// the model so an unrelated state change (a sheet presenting, a
    /// selection) reads the cache instead of re-running the pipeline
    /// for every visible paragraph.
    private func rendered(_ text: String, doc: LiquidDoc,
                          paragraphID: String? = nil) -> AttributedString {
        guard let paragraphID else {
            return renderedNow(text, doc: doc, paragraphID: nil)
        }
        // Every input that shapes the outcome keys the cache; reading
        // the stamp here also keeps the repaint-on-annotate observation
        // alive when every paragraph is a hit.
        let signature = [docID,
                         citationStyle.rawValue,
                         String(describing: readingScheme),
                         String(bionicReading),
                         String(model.annotationsStamp),
                         openInlineNotes.sorted().joined(separator: ","),
                         findQuery ?? ""].joined(separator: "|")
        return model.renderedText(paragraphID, text: text, signature: signature) {
            renderedNow(text, doc: doc, paragraphID: paragraphID)
        }
    }

    private func renderedNow(_ text: String, doc: LiquidDoc,
                             paragraphID: String?) -> AttributedString {
        var out = OrigamiReading.inlineAttributed(text, in: doc,
                                                  citations: citationStyle,
                                                  appearance: readingScheme)
        out = OrigamiReading.inlineNotesResolved(out, in: doc,
                                                 open: openInlineNotes,
                                                 citations: citationStyle,
                                                 appearance: readingScheme)
        if bionicReading { out = Self.bionic(out) }
        if let paragraphID { out = painted(out, paragraphID: paragraphID) }
        // Find's marks: every occurrence of the sought words, wherever
        // the reading shows this paragraph.
        if let query = findQuery?.trimmingCharacters(in: .whitespaces), !query.isEmpty {
            let plain = String(out.characters)
            var from = plain.startIndex
            while let found = plain.range(of: query, options: .caseInsensitive,
                                          range: from..<plain.endIndex) {
                if let attrRange = Range(found, in: out) {
                    out[attrRange].backgroundColor = Color.yellow.opacity(0.45)
                }
                from = found.upperBound
            }
        }
        return out
    }

    /// Bold the first half of every word — the Mac's bionic pass, on
    /// AttributedString. Ranges gather first; attributes apply after,
    /// so run coalescing never shifts the walk.
    private static func bionic(_ text: AttributedString) -> AttributedString {
        var out = text
        let wordChars = CharacterSet.alphanumerics
        var ranges: [Range<AttributedString.Index>] = []
        let chars = out.characters
        var i = chars.startIndex
        while i < chars.endIndex {
            while i < chars.endIndex,
                  !(chars[i].unicodeScalars.allSatisfy { wordChars.contains($0) }) {
                i = chars.index(after: i)
            }
            guard i < chars.endIndex else { break }
            let start = i
            while i < chars.endIndex,
                  chars[i].unicodeScalars.allSatisfy({ wordChars.contains($0) }) {
                i = chars.index(after: i)
            }
            let length = chars.distance(from: start, to: i)
            guard length >= 2 else { continue }
            let boldEnd = chars.index(start, offsetBy: max(1, Int((Double(length) / 2).rounded(.up))))
            ranges.append(start..<boldEnd)
        }
        for range in ranges {
            let existing = out[range].inlinePresentationIntent ?? []
            out[range].inlinePresentationIntent = existing.union(.stronglyEmphasized)
        }
        return out
    }

    // MARK: The Word assist (RSVP)

    /// One word at a time, centre screen — the Mac's Word assist:
    /// play/pause, five back or forward, the pace in words a minute.
    private var rsvpOverlay: some View {
        ZStack {
            pageColor.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()
                Text(rsvpWords.isEmpty ? "" : rsvpWords[min(rsvpWordIndex, rsvpWords.count - 1)])
                    .font(.system(size: 34 + fontDelta, design: .serif))
                    .foregroundStyle(inkStyle)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.05), value: rsvpWordIndex)
                Text("\(rsvpWordIndex + 1) / \(rsvpWords.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 28) {
                    Button { rsvpWordIndex = max(rsvpWordIndex - 5, 0) } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button {
                        rsvpPlaying.toggle()
                        if rsvpPlaying { stepRSVP() }
                    } label: {
                        Image(systemName: rsvpPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Button { rsvpWordIndex = min(rsvpWordIndex + 5, max(rsvpWords.count - 1, 0)) } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(inkStyle)
                HStack(spacing: 10) {
                    Button { rsvpWPM = max(rsvpWPM - 25, 60) } label: {
                        Image(systemName: "minus.circle")
                    }
                    Text("\(Int(rsvpWPM)) wpm")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 80)
                    Button { rsvpWPM = min(rsvpWPM + 25, 800) } label: {
                        Image(systemName: "plus.circle")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button("Close") {
                    rsvpPlaying = false
                    showsRSVP = false
                }
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)
            }
        }
    }

    private func beginRSVP(_ sections: [OrigamiSection]) {
        let index = min(max(focusIndex, 0), max(sections.count - 1, 0))
        guard index < sections.count else { return }
        let whole = sections[index].paragraphs.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: #"\[(cite|note|inote):[^\]]*\]"#,
                                  with: "", options: .regularExpression)
        rsvpWords = whole.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        rsvpWordIndex = 0
        showsRSVP = true
        rsvpPlaying = true
        stepRSVP()
    }

    private func stepRSVP() {
        guard rsvpPlaying else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60.0 / max(rsvpWPM, 60)))
            guard rsvpPlaying, showsRSVP else { return }
            if rsvpWordIndex < rsvpWords.count - 1 {
                rsvpWordIndex += 1
                stepRSVP()
            } else {
                rsvpPlaying = false
            }
        }
    }

    // MARK: Furniture

    /// The reading's foot bar — the headset's, sized for a hand: the
    /// view words, then Contents, the theme, and the type size.
    /// The modes on offer by word: Outline is absent — pinching in is
    /// its door now — but stays reachable, and while it is up the view
    /// it will return to reads as the chosen word.
    /// The open document's title, for the horizontal bar.
    private var documentTitle: String {
        model.index.byID[docID]?.doc.title
            ?? model.epubRecords.first { $0.id == docID }?.title
            ?? ""
    }

    private var footBar: some View {
        HStack(spacing: 6) {
            // The way back, said in words: to the documents.
            Button {
                dismiss()
            } label: {
                if opensOverBook {
                    Image(systemName: "chevron.backward")
                        .foregroundStyle(Self.inactiveBarGrey)
                        .accessibilityLabel("Back to the citing document")
                } else {
                    Text("Documents")
                        .font(.subheadline)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Self.inactiveBarGrey)
                        .accessibilityHint("Back to the document list")
                }
            }
            .buttonStyle(.plain)
            // Horizontal reads like a spread: the document's title
            // rides the bar, cropped with … when the room runs out —
            // sized to stay clear of the centred mode words.
            if mode == .horizontal || (mode == .outline && outlineReturnMode == .horizontal) {
                Text(documentTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 420, alignment: .leading)
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Appearance", selection: $themeRaw) {
                    ForEach(PhoneReadingTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                Picker("Theme", selection: $readerThemeRaw) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                Toggle("Bionic Reading", isOn: $bionicReading)
            } label: {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            Menu {
                Button("Bigger") { fontDelta = min(fontDelta + 1, 12) }
                Button("Smaller") { fontDelta = max(fontDelta - 1, -4) }
                Divider()
                Button("Reset Size") { fontDelta = 0 }
            } label: {
                Text("Aa")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        // On iPad the bar's controls hold to a book's width, centred,
        // instead of flying to the screen's far corners — except in
        // Horizontal, whose full-width spread earns a full-width bar
        // with room for the title.
        .frame(maxWidth: mode == .horizontal
               || (mode == .outline && outlineReturnMode == .horizontal)
               ? .infinity : 640)
        // The mode words sit dead centre of the bar, riding over the
        // chevron-and-menus row rather than between its ends.
        .overlay {
            HStack(spacing: 6) {
                ForEach(Array(Mode.allCases.filter {
                    $0 != .outline && ($0 != .horizontal || offersHorizontal)
                }.enumerated()), id: \.offset) { index, word in
                    if index > 0 { separator }
                    modeWord(word.word,
                             chosen: mode == word
                                 || (mode == .outline && outlineReturnMode == word)) {
                        // A mode word always shows its own view: the
                        // word-reader steps aside first, or Scroll
                        // appears to do nothing under its overlay.
                        rsvpPlaying = false
                        showsRSVP = false
                        modeRaw = word.rawValue
                        if word == .focus { focusIndex = 0 }
                    }
                }
            }
        }
        // The foot bar is always black, whatever the page or the system
        // wear — dark scheme so its words and icons read light.
        .frame(maxWidth: .infinity)
        .background(Color.black.ignoresSafeArea(edges: .bottom))
        .environment(\.colorScheme, .dark)
    }

    /// Focus's second row: [ Section | Sentence | Paragraph | Word ] —
    /// the Mac's assists, in the same black dress as the foot bar. A
    /// section is a heading and everything under it until the next one.
    private var assistBar: some View {
        HStack(spacing: 6) {
            Text("[").foregroundStyle(.tertiary)
            modeWord("Section", chosen: assist == .section) {
                assistRaw = Assist.section.rawValue
            }
            separator
            modeWord("Sentence", chosen: assist == .sentence) {
                sentenceIndex = 0
                assistRaw = Assist.sentence.rawValue
            }
            separator
            modeWord("Paragraph", chosen: assist == .paragraph) {
                paragraphIndex = 0
                assistRaw = Assist.paragraph.rawValue
            }
            separator
            modeWord("Word", chosen: showsRSVP) {
                if let doc = model.index.byID[docID]?.doc {
                    beginRSVP(OrigamiSection.build(from: doc))
                }
            }
            Text("]").foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        // Centred like the mode words below it; the black spans the bar.
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 14)
    }

    /// The grey of a toolbar word not chosen — shared by the step bar's
    /// section title and arrows, so they read as part of the toolbar.
    private static let inactiveBarGrey = Color(white: 0.45)

    private func modeWord(_ word: String, chosen: Bool, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(word)
                .font(.subheadline.weight(chosen ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                // Quiet greys on the black bar — words a shade darker
                // than the bar's icons, present without shouting.
                .foregroundStyle(chosen ? Color(white: 0.72) : Self.inactiveBarGrey)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The selection menu

/// The selection's verbs as a vertical card — every one visible at
/// once, anchored beside the selected words. Highlight unfolds its
/// kinds in place; a tap anywhere else puts the card away.
private struct SelectionMenuCard: View {
    let anchor: CGRect   // window coordinates
    let highlightsPresent: Bool
    let onFind: () -> Void
    let onCopyCitation: () -> Void
    /// Whether the book is already To Read — the row then takes it off.
    let isToRead: Bool
    let onToRead: () -> Void
    let onHighlight: (ReaderAnnotationKind) -> Void
    let onRemoveHighlights: () -> Void
    let onNote: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @State private var showsKinds = false

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let width: CGFloat = 240
            let rowHeight: CGFloat = 40
            let height = rowHeight * 6
                + (showsKinds ? rowHeight * CGFloat(ReaderAnnotationKind.allCases.count + 1) : 0)
            // Beside the words: below when there is room, above otherwise,
            // clamped to the reading's edges.
            let x = min(max(anchor.midX - frame.minX, width / 2 + 12),
                        frame.width - width / 2 - 12)
            let below = anchor.maxY - frame.minY + height / 2 + 10
            let above = anchor.minY - frame.minY - height / 2 - 10
            let y = below + height / 2 < frame.height - 20
                ? below
                : max(above, height / 2 + 10)

            ZStack {
                // The way out: any tap beside the card.
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
                VStack(spacing: 0) {
                    row("Find", symbol: "magnifyingglass", action: onFind)
                    Divider()
                    row("Copy Citation", symbol: "quote.opening", action: onCopyCitation)
                    Divider()
                    row(isToRead ? "Remove from To Read" : "To Read",
                        symbol: isToRead ? "bookmark.slash" : "bookmark", action: onToRead)
                    Divider()
                    Button {
                        withAnimation(.snappy) { showsKinds.toggle() }
                    } label: {
                        HStack {
                            Label("Highlight", systemImage: "highlighter")
                            Spacer()
                            Image(systemName: showsKinds ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showsKinds {
                        ForEach(ReaderAnnotationKind.allCases) { kind in
                            Divider().padding(.leading, 14)
                            row(PhoneAnnotationInk.displayName(of: kind),
                                symbol: kind.systemImage,
                                indented: true) { onHighlight(kind) }
                        }
                        Divider().padding(.leading, 14)
                        row("Remove", symbol: "eraser", indented: true,
                            destructive: true, action: onRemoveHighlights)
                    }
                    Divider()
                    row("Note\u{2026}", symbol: "square.and.pencil", action: onNote)
                    Divider()
                    row("Copy", symbol: "doc.on.doc", action: onCopy)
                }
                .frame(width: width)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
                .shadow(radius: 14, y: 4)
                .position(x: x, y: y)
            }
        }
    }

    private func row(_ title: String, symbol: String, indented: Bool = false,
                     destructive: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                Spacer()
            }
            .padding(.leading, indented ? 28 : 14)
            .padding(.trailing, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Selectable paragraphs

/// The annotation kinds' inks — the Mac's AnnotationKindStyle, phone-
/// sized: the same UserDefaults keys and default colours, so a kind
/// renamed or recoloured on the Mac reads the same here. Keep in step
/// (AnnotationsListView.swift holds the original).
enum PhoneAnnotationInk {
    static func displayName(of kind: ReaderAnnotationKind) -> String {
        let names = UserDefaults.standard.dictionary(forKey: "annotationKindNames")
            as? [String: String]
        let custom = names?[kind.rawValue]?.trimmingCharacters(in: .whitespaces)
        return custom?.isEmpty == false ? custom! : kind.rawValue
    }

    static func defaultHex(of kind: ReaderAnnotationKind) -> String {
        switch kind {
        case .important: "E4572E"
        case .quotable: "2E8B8B"
        case .great: "3A9B35"
        case .disagree: "C93C3C"
        case .languageIssue: "8E5BC0"
        case .problematic: "D98E1B"
        case .whatIsThis: "3B6FD4"
        case .highlight: "E8C51D"
        case .strikethrough: "8A8A8A"
        }
    }

    static func color(of kind: ReaderAnnotationKind) -> Color {
        let colors = UserDefaults.standard.dictionary(forKey: "annotationKindColors")
            as? [String: String]
        let hex = colors?[kind.rawValue] ?? defaultHex(of: kind)
        return Color(hexCode: hex) ?? .yellow
    }
}

/// One paragraph as a real text view: live selection with the reader's
/// verbs on it — Copy, Copy Citation, Highlight, Note — the Mac's
/// SelectableParagraph, phone-sized. Links route to the reader's cards
/// and wear the body's ink, never blue.
private struct PhoneSelectableParagraph: UIViewRepresentable {
    let attributed: AttributedString
    let baseSize: CGFloat
    let inkColor: UIColor?
    let lineSpacing: CGFloat
    /// A link was tapped; true means the reader handled it.
    let onLink: (URL) -> Bool
    /// A selection asked for its menu: the exact words, their
    /// neighbours, and where the words stand on screen (window
    /// coordinates) — the reader shows its own vertical menu there.
    let onSelectionMenu: (String, String?, String?, CGRect) -> Void
    /// Bumped by the reader when its menu closes: the selection drops.
    var clearSelectionToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PhoneSelectableParagraph
        /// The last clear ask this paragraph has answered.
        var clearedSelectionToken = 0
        init(_ parent: PhoneSelectableParagraph) { self.parent = parent }

        func textView(_ textView: UITextView, shouldInteractWith url: URL,
                      in characterRange: NSRange,
                      interaction: UITextItemInteraction) -> Bool {
            !parent.onLink(url)
        }

        /// The selection and its neighbours (32 characters each side),
        /// the annotation's disambiguating context.
        private func pieces(of textView: UITextView, in range: NSRange)
            -> (selected: String, prefix: String?, suffix: String?)? {
            let full = textView.text ?? ""
            guard range.length > 0, let swiftRange = Range(range, in: full) else { return nil }
            let selected = String(full[swiftRange])
            guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let prefix = String(full[..<swiftRange.lowerBound].suffix(32))
            let suffix = String(full[swiftRange.upperBound...].prefix(32))
            return (selected, prefix.isEmpty ? nil : prefix, suffix.isEmpty ? nil : suffix)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let pieces = pieces(of: textView, in: range) else { return nil }
            // Where the selected words stand, in window coordinates —
            // the reader anchors its own menu there.
            var rect = textView.bounds
            if let start = textView.position(from: textView.beginningOfDocument,
                                             offset: range.location),
               let end = textView.position(from: start, offset: range.length),
               let textRange = textView.textRange(from: start, to: end) {
                rect = textView.firstRect(for: textRange)
            }
            let global = textView.convert(rect, to: nil)
            parent.onSelectionMenu(pieces.selected, pieces.prefix, pieces.suffix, global)
            // The system's horizontal bar steps aside: two visible verbs
            // and a > was too little room. An empty menu suppresses it;
            // the reader's vertical card carries every verb instead.
            return UIMenu(children: [])
        }
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.clearedSelectionToken != clearSelectionToken {
            context.coordinator.clearedSelectionToken = clearSelectionToken
            view.selectedTextRange = nil
        }
        view.linkTextAttributes = [.foregroundColor: inkColor ?? UIColor.label]
        let converted = converted()
        // Replacing the text drops any live selection; only real
        // content changes are worth that.
        if view.attributedText?.isEqual(to: converted) != true {
            view.attributedText = converted
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView,
                      context: Context) -> CGSize? {
        // Measure at the proposed width; when none is proposed, at the
        // width the view actually has, so every pass agrees (the Mac's
        // SelectableParagraph learnt this the hard way).
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (uiView.bounds.width > 0 ? uiView.bounds.width : 360)
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    /// The AttributedString with its semantic runs resolved into UIKit
    /// attributes — presentation intents to bold/italic/monospace on the
    /// serif base, colours and links carried across. The Mac's
    /// SelectableParagraph.converted() is the sibling; keep in step.
    private func converted() -> NSAttributedString {
        let plain = UIFont.systemFont(ofSize: baseSize)
        let serif = plain.fontDescriptor.withDesign(.serif)
            .map { UIFont(descriptor: $0, size: baseSize) } ?? plain
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            var font = serif
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: baseSize * 0.92, weight: .regular)
                }
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty,
                   let descriptor = font.fontDescriptor.withSymbolicTraits(
                       font.fontDescriptor.symbolicTraits.union(traits)) {
                    font = UIFont(descriptor: descriptor, size: baseSize)
                }
            }
            let ink = run.foregroundColor.map(UIColor.init) ?? inkColor ?? .label
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: ink,
                .paragraphStyle: paragraphStyle,
            ]
            if let background = run.backgroundColor {
                attributes[.backgroundColor] = UIColor(background)
            }
            if let link = run.link {
                attributes[.link] = link
                // The Mac's rule travels: body-ink links with a quiet
                // underline, so a jump or a web link shows it can be
                // tapped. Controls (notes, glossary, stretch) and
                // bracketed or raised citations — marks already —
                // carry none.
                let numberedCitation = link.scheme == "origami-cite"
                    && OrigamiCitationStyle(rawValue: UserDefaults.standard.string(
                        forKey: "origamiCitationStyle") ?? "") ?? .authorDate != .authorDate
                let control = ["origami-note", "origami-inote", "origami-gloss",
                               "origami-stretch", "origami-conceptcard"]
                    .contains(link.scheme ?? "")
                if !control, !numberedCitation {
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.underlineColor] = ink.withAlphaComponent(0.35)
                }
            }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
    }
}

// MARK: - The guide

/// The shelf's third face: how to read here — one screen of it, no
/// setup, readable before the first book ever arrives.
struct PhoneGuideView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // The two books shipped with the app, opened in the
                // reader like any other — the summary below is the
                // one-screen version.
                VStack(spacing: 0) {
                    bookRow("Introduction", symbol: "book",
                            detail: "Welcome to Origami Text",
                            record: model.introductionRecord)
                    Divider().padding(.leading, 44)
                    bookRow("User Guide", symbol: "questionmark.circle",
                            detail: UIDevice.current.userInterfaceIdiom == .pad
                                ? "Everything the iPad does" : "Everything the iPhone does",
                            record: model.userGuideRecord)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                Text("Origami Text reads research papers and letters whose citations, notes and structure stay alive — EPUBs published from Origami Text on the Mac, from Author, or any EPUB you have.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                guideRow("books.vertical", "Getting books in",
                         "Tap the gear and Open EPUB…, open one straight from the Files app or a share sheet, or choose the iCloud folder your community shares — everything published from a Mac appears on the shelf by itself.")
                guideRow("book", "Ways to read",
                         "Scroll lays the whole text in one clean column. Focus holds one section at a time — with Previous and Next at the bottom. On iPad, Horizontal stands the sections side by side, each its own column.")
                guideRow("arrow.down.right.and.arrow.up.left", "Pinch for the outline",
                         "Pinch in anywhere while reading and the book folds into its outline. Pinch out and it opens again at the very spot you left. Tap a heading's name to open that section instead; the chevron beside it peeks inside without leaving.")
                guideRow("quote.closing", "Citations and notes",
                         "Tap a citation — [1] or (Author 2026) — and its source appears as a card, with the full reference a copy away. Tap a note's raised number (or its ‡ mark) for the note behind it. How citations and notes read is yours to choose in Settings.")
                guideRow("pin", "Pin and set aside",
                         "Swipe a book right to pin it to the top of every list; swipe left to set it aside for later — or hold for the menu. The standing is shared: your Mac and headset see the same pile.")
                guideRow("circle.lefthalf.filled", "Looks",
                         "The half-circle in the foot bar holds Light and Dark, the colour themes — sepia through the dyslexia-friendly palettes — and Bionic Reading. Aa makes the words bigger or smaller.")
                guideRow("text.line.first.and.arrowtriangle.forward", "Focus assists",
                         "In Focus, the upper row offers one sentence or one paragraph at a time — or Word, which plays the text one word after another at your pace (set in Settings).")
            }
            .padding(20)
        }
    }

    /// One shipped book: tap and it opens in the reader. Greyed when the
    /// book is not in this copy of the app.
    private func bookRow(_ title: String, symbol: String, detail: String,
                         record: EPUBRecord?) -> some View {
        Button {
            if let record { model.readerRecordID = record.id }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(record == nil)
    }

    private func guideRow(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The citation card

/// The tapped citation's source, card-presented: the visionOS
/// citation sheet's sibling — title, authors, year, the DOI or URL as
/// a live link, and the BibTeX a long press away.
private struct PhoneCitationCard: View {
    let doc: LiquidDoc
    let key: String
    /// Opens a cited document that is on the shelf, over the citing one.
    let openOnShelf: (String) -> Void
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The cited document on this shelf, if it is here — named by the
    /// reference's vm-id, by an origamitext://open/<address> url, or by
    /// the citation key itself (an internal citation's key is the cited
    /// document's address). The Mac's Open Original, here.
    private func shelfRecord(fields: [String: String]) -> EPUBRecord? {
        var addresses: [String] = []
        if let vmID = fields["vm-id"] { addresses.append(vmID) }
        if let url = fields["url"].flatMap(URL.init(string:)),
           url.scheme?.lowercased() == "origamitext" {
            addresses.append(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        addresses.append(key)
        for address in addresses where !address.isEmpty {
            if let record = model.epubRecords.first(where: {
                $0.id == address || $0.folder == address
            }) {
                return record
            }
        }
        return nil
    }

    var body: some View {
        // An internal citation's key is the cited document's address —
        // the link to it carries its own BibTeX, as on the Mac.
        let reference = doc.references.first { $0.id == key }
            ?? doc.links.first { $0.to == key }?.bibtex
                .map { LiquidDoc.Reference(id: key, bibtex: $0) }
        let fields = reference.flatMap { BibTeXParser.first($0.bibtex)?.fields } ?? [:]
        let title = fields["title"] ?? reference?.citedAs ?? key
        let author = fields["author"] ?? ""
        let year = fields["year"] ?? ""
        let venue = fields["journal"] ?? fields["booktitle"] ?? fields["publisher"] ?? ""
        let doi = fields["doi"]
        // An app link is not a web page: Open stands in for it.
        let urlField = fields["url"].flatMap {
            URL(string: $0)?.scheme?.lowercased() == "origamitext" ? nil : $0
        }
        let onShelf = shelfRecord(fields: fields)
        NavigationStack {
            List {
                Section {
                    Text(title).font(.headline)
                    if !author.isEmpty || !year.isEmpty {
                        Text([author, year].filter { !$0.isEmpty }
                            .joined(separator: " \u{00B7} "))
                            .foregroundStyle(.secondary)
                    }
                    if !venue.isEmpty {
                        Text(venue).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    if let onShelf {
                        Button {
                            dismiss()
                            openOnShelf(onShelf.id)
                        } label: {
                            Label("Open", systemImage: "book")
                        }
                    }
                    if let doi, !doi.isEmpty,
                       let url = URL(string: doi.hasPrefix("http")
                                     ? doi : "https://doi.org/" + doi) {
                        Link(destination: url) {
                            Label("DOI", systemImage: "link")
                        }
                    }
                    if let urlField, !urlField.isEmpty, let url = URL(string: urlField) {
                        Link(destination: url) {
                            Label("Web", systemImage: "safari")
                        }
                    }
                    // A web search for the work — title, author, year —
                    // as the Mac's card offers.
                    Button {
                        var terms = ["\"\(title)\""]
                        if !author.isEmpty { terms.append(author) }
                        if !year.isEmpty { terms.append(String(year.prefix(4))) }
                        var components = URLComponents(string: "https://www.google.com/search")!
                        components.queryItems = [URLQueryItem(name: "q",
                                                              value: terms.joined(separator: " "))]
                        if let url = components.url { openURL(url) }
                    } label: {
                        Label("Online", systemImage: "globe")
                    }
                    if let bibtex = reference?.bibtex, !bibtex.isEmpty {
                        Button {
                            UIPasteboard.general.string = bibtex
                        } label: {
                            Label("Copy BibTeX", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
            .navigationTitle("Citation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The figure an in-document jump names, card-presented: the image
/// with its printed caption — seen without leaving the words.
private struct PhoneFigureCard: View {
    let doc: LiquidDoc
    let paragraphID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let paragraph = doc.body?.first(where: { $0.id == paragraphID }),
                       let reference = LiquidDoc.imageReference(in: paragraph.text),
                       let asset = doc.assets.first(where: { $0.id == reference.id }),
                       let image = decodedImage(for: asset) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                        if let caption = asset.alt, !caption.isEmpty {
                            Text(caption)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text("The figure is not in this copy of the document.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Figure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The tapped dagger's endnote, card-presented, its own links live.
private struct PhoneEndnoteCard: View {
    let doc: LiquidDoc
    let noteID: String
    let style: OrigamiCitationStyle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(OrigamiReading.endnote(withID: noteID, in: doc)
                    .map { OrigamiReading.inlineAttributed($0.text, in: doc,
                                                           citations: style,
                                                           appearance: colorScheme) }
                    ?? AttributedString("The document carries no note \(noteID)."))
                    .font(.system(size: 16, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - The To Read press

/// A one-second press on the page around a paragraph — its margins and
/// the gaps either side — marks To Read there. It sits BEHIND the words:
/// a press on the words themselves goes to them and selects, as always,
/// and the selection card carries To Read for that case.
private struct ToReadPress: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                // Out into the side margins and half of each gap between
                // paragraphs, so blank page space is all covered.
                .padding(.vertical, -7)
                .padding(.horizontal, -20)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1, perform: action)
        }
    }
}

/// Settings ▸ On Loading: what the reader shows while a book arrives.
enum LoadingStyle: String, CaseIterable, Identifiable {
    case spinner, animation
    static let defaultsKey = "iosLoadingStyle"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .spinner: "Spinner"
        case .animation: "Animation"
        }
    }
}

// MARK: - Tapping the sides

/// In Focus's Sentence and Paragraph: a tap in the right edge's strip
/// steps on, in the left edge's strip steps back — the way a page is
/// turned. Each strip is a tenth of the width, so the words between stay
/// free to select.
private struct TapSides: ViewModifier {
    let step: (Int) -> Void

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                let strip = geometry.size.width * 0.1
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: strip)
                        .contentShape(Rectangle())
                        .onTapGesture { step(-1) }
                        .accessibilityLabel("Previous")
                        .accessibilityAddTraits(.isButton)
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                    Color.clear
                        .frame(width: strip)
                        .contentShape(Rectangle())
                        .onTapGesture { step(1) }
                        .accessibilityLabel("Next")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }
}
