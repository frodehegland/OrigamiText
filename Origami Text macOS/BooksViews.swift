import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Library ▸ Books: every book the reader has, in any form — and the
/// spines a shelf photograph left unsure. Drop a photo of books on the
/// list (or take one with the iPhone, File ▸ Import from iPhone or iPad)
/// and the books on it arrive. The foot Find narrows the list.
struct BooksListView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("booksSortKey") private var sortKey = "title"
    @AppStorage("booksSortAscending") private var ascending = true
    @State private var dropTargeted = false

    /// The foot Find over a book's title, authors, publisher, ISBN and
    /// where it stands.
    private func found(_ text: String) -> Bool { model.matchesFind(text) }

    private var sorted: [BookEntry] {
        let books = model.booksShown.filter { book in
            found(([book.title, book.publisher ?? "", book.location ?? ""] + book.authors + book.isbns)
                .joined(separator: " "))
        }
        let ordered: [BookEntry]
        switch sortKey {
        case "author":
            ordered = books.sorted {
                surname($0).localizedStandardCompare(surname($1)) == .orderedAscending
            }
        case "date":
            ordered = books.sorted { ($0.year ?? Int.min) > ($1.year ?? Int.min) }
        default:
            ordered = books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let flipped = sortKey == "date" ? !ascending : ascending
        return flipped ? ordered : ordered.reversed()
    }

    private func surname(_ book: BookEntry) -> String {
        book.authors.first?.split(separator: " ").last.map(String.init) ?? "\u{FFFF}"
    }

    var body: some View {
        VStack(spacing: 0) {
            AuthorSortTabs(key: $sortKey, ascending: $ascending, tabs: SortTab.works)
            if let status = model.booksStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
            List {
                let unsure = model.unsureSpines.filter { found($0.text) }
                if !unsure.isEmpty {
                    Section("Not Sure") {
                        ForEach(unsure) { spine in
                            UnsureSpineRow(spine: spine)
                        }
                    }
                }
                Section {
                    ForEach(sorted) { book in
                        BookRow(book: book, sortKey: sortKey)
                    }
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
            // The list takes the drop itself — a table under the pointer
            // would otherwise refuse it before the pane saw it.
            .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted, perform: dropped)
            .overlay {
                if model.booksShown.isEmpty && model.unsureSpines.isEmpty {
                    ContentUnavailableView {
                        Label("No Books Yet", systemImage: "books.vertical")
                    } description: {
                        Text("Drop a photo of your books here \u{2014} a shelf of spines or one cover \u{2014} or take one with your iPhone: File \u{25B8} Import from iPhone or iPad. Books in the library appear here too.")
                    }
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).padding(4)
            }
        }
        // A photo dropped anywhere on Books is read for its books: a
        // file from Finder, a picture dragged out of Photos or a browser,
        // a screenshot's thumbnail — a shelf of spines or one cover.
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted, perform: dropped)
        .task { model.migratePageNotes() }
        // Continuity Camera: the photo the iPhone takes arrives here.
        .importsItemProviders([.image]) { providers in
            Task { await readFromProviders(providers) }
            return !providers.isEmpty
        }
    }

    /// A drop: picture files by their URL, everything else by its image
    /// data. Anything that is no picture is declined.
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !usable.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in usable {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await Self.fileURL(from: provider) {
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false {
                        urls.append(url)
                    }
                    continue
                }
                let data: Data? = await withCheckedContinuation { done in
                    _ = provider.loadDataRepresentation(for: .image) { data, _ in done.resume(returning: data) }
                }
                if let data, let url = Self.temporaryPhoto(data, ext: nil) { urls.append(url) }
            }
            if urls.isEmpty {
                model.showNote("That drop held no photo to read \u{2014} drop a picture of books")
            } else {
                model.readShelfPhotos(urls, location: nil)
            }
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
        }
    }

    /// Pictures handed over by Continuity Camera (or Services).
    private func readFromProviders(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            let data: Data? = await withCheckedContinuation { done in
                _ = provider.loadDataRepresentation(for: .image) { data, _ in done.resume(returning: data) }
            }
            if let data, let url = Self.temporaryPhoto(data, ext: nil) { urls.append(url) }
        }
        model.readShelfPhotos(urls, location: nil)
    }

    private static func temporaryPhoto(_ data: Data, ext: String?) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shelf Photo \(UUID().uuidString.prefix(8)).\(ext ?? "jpg")")
        return (try? data.write(to: url)) != nil ? url : nil
    }
}

/// One book: as the sort reads it, and the forms it is held in.
private struct BookRow: View {
    @Environment(AppModel.self) private var model
    let book: BookEntry
    let sortKey: String

    var body: some View {
        let chosen = model.selectedBookID == book.id
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                switch sortKey {
                case "author":
                    Text(book.authorLine.isEmpty ? book.title : book.authorLine)
                        .font(.system(size: 12.5))
                    if book.authorLine.isEmpty == false {
                        Text(book.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                case "date":
                    Text(book.title).font(.system(size: 12.5)).lineLimit(2)
                    Text([book.authorLine, book.year.map(String.init) ?? ""].filter { !$0.isEmpty }
                        .joined(separator: " \u{00B7} "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                default:
                    Text(book.title).font(.system(size: 12.5)).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            BookFormIcons(book: book)
        }
        .padding(.vertical, 3)
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            if chosen { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.openEPUB = nil
            model.selectedBookID = book.id
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// The forms a book is held in, as small marks.
struct BookFormIcons: View {
    let book: BookEntry

    var body: some View {
        HStack(spacing: 4) {
            if book.inPrint { mark("book.closed", "In print") }
            if book.libraryFolder != nil { mark("doc.text", "In the library") }
            if book.appleBooksID != nil { mark("apple.logo", "In Apple Books") }
            if book.kindleASIN != nil { mark("k.circle", "In Kindle") }
            if book.openCopyURL != nil { mark("lock.open", "Open-rights copy") }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func mark(_ symbol: String, _ help: String) -> some View {
        Image(systemName: symbol).help(help)
    }
}

/// A spine Origami was not sure of: its picture and what it read.
private struct UnsureSpineRow: View {
    @Environment(AppModel.self) private var model
    let spine: UnsureSpine

    var body: some View {
        let chosen = model.selectedBookID == "unsure:" + spine.id
        HStack(spacing: 8) {
            SpineImage(spine: spine).frame(width: 70, height: 22)
            Text(spine.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            if chosen { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.openEPUB = nil
            model.selectedBookID = "unsure:" + spine.id
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private struct SpineImage: View {
    @Environment(AppModel.self) private var model
    let spine: UnsureSpine

    var body: some View {
        if let name = spine.cropName, let image = NSImage(contentsOf: model.spineCropURL(name)) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "books.vertical").foregroundStyle(.tertiary))
        }
    }
}

/// The Books detail pane: the chosen book, or the chosen unsure spine.
struct BooksDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.selectedBookID, id.hasPrefix("unsure:"),
           let spine = model.unsureSpines.first(where: { "unsure:" + $0.id == id }) {
            UnsureSpineDetail(spine: spine).id(spine.id)
        } else if let id = model.selectedBookID, let book = model.book(withID: id) {
            BookDetailView(book: book).id(book.id)
        } else {
            ContentUnavailableView("No Book Selected", systemImage: "books.vertical",
                                   description: Text("Choose a book to see the forms you have it in, and to find others."))
        }
    }
}

/// One book: what it is, the forms it is held in — each opening where
/// it lives — the ways to find it digitally, and notes by page.
private struct BookDetailView: View {
    @Environment(AppModel.self) private var model
    let book: BookEntry
    @State private var storeBooks: [BookLookup.StoreBook]?
    @State private var openCopies: [BookLookup.OpenCopy]?
    @State private var searching = false
    @State private var kindleLink = ""
    @State private var kindleProblem = false
    @State private var notePage = ""
    @State private var notePassage = ""
    @State private var noteText = ""
    @State private var annotations: [WebAnnotation] = []

    private func change(_ edit: (inout BookEntry) -> Void) {
        var copy = model.book(withID: book.id) ?? book
        edit(&copy)
        model.updateBook(copy)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                forms
                Divider()
                findDigital
                Divider()
                notes
                if !book.id.hasPrefix("library:") {
                    Button("Remove from Books", role: .destructive) { model.removeBook(book.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if let cover = book.coverURL.flatMap(URL.init(string:)) {
                AsyncImage(url: cover) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                }
                .frame(width: 90, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                if !book.authors.isEmpty {
                    Text(book.authorLine).font(.title3).foregroundStyle(.secondary)
                }
                Text([book.year.map(String.init), book.publisher].compactMap { $0 }
                    .joined(separator: " \u{00B7} "))
                    .font(.callout).foregroundStyle(.secondary)
                if let isbn = book.isbns.first {
                    Text("ISBN \(isbn)").font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }
                if let source = book.source {
                    Text("Added from \(source.lowercased()) \u{00B7} \(book.added.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Forms

    private var forms: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You Have It").font(.headline)
            HStack {
                Toggle("In print", isOn: Binding(get: { book.inPrint },
                                                 set: { value in change { $0.inPrint = value } }))
                TextField("Where it stands", text: Binding(
                    get: { book.location ?? "" },
                    set: { value in change { $0.location = value.isEmpty ? nil : value } }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!book.inPrint)
            }
            if model.libraryRecord(for: book) != nil {
                formRow("doc.text", "In the library") {
                    Button("Open") { model.openLibraryCopy(book) }
                }
            }
            if book.appleBooksID != nil {
                formRow("apple.logo", "Apple Books") {
                    Button("Open in Books") { model.openInAppleBooks(book) }
                    Button("Unlink") { change { $0.appleBooksID = nil; $0.appleBooksURL = nil } }
                        .foregroundStyle(.secondary)
                }
            }
            if let asin = book.kindleASIN {
                formRow("k.circle", "Kindle \u{00B7} \(asin)") {
                    Button("Open in Kindle") { model.openInKindle(book) }
                    Button("Unlink") { change { $0.kindleASIN = nil } }
                        .foregroundStyle(.secondary)
                }
            }
            if let open = book.openCopyURL, model.libraryRecord(for: book) == nil {
                formRow("lock.open", "Open-rights copy") {
                    Button("Open") { if let url = URL(string: open) { NSWorkspace.shared.open(url) } }
                }
            }
        }
    }

    private func formRow<Buttons: View>(_ symbol: String, _ title: String,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(title)
            Spacer()
            buttons()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Finding it digitally

    private var findDigital: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Find It Digitally").font(.headline)
                Spacer()
                if searching { ProgressView().controlSize(.small) }
                Button("Search") { Task { await search() } }
                    .disabled(searching)
            }
            if let storeBooks {
                Text("Apple Books").font(.subheadline.weight(.semibold))
                if storeBooks.isEmpty {
                    Text("Not found in the Apple Books Store.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(storeBooks) { store in
                    HStack(spacing: 10) {
                        if let art = store.artwork.flatMap(URL.init(string:)) {
                            AsyncImage(url: art) { $0.resizable().aspectRatio(contentMode: .fit) }
                                placeholder: { Color.secondary.opacity(0.1) }
                                .frame(width: 28, height: 40)
                        }
                        VStack(alignment: .leading) {
                            Text(store.title).font(.callout).lineLimit(2)
                            Text([store.author, store.price ?? ""].filter { !$0.isEmpty }
                                .joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(book.appleBooksID == store.id ? "Linked" : "Link") {
                            change { $0.appleBooksID = store.id; $0.appleBooksURL = store.url }
                        }
                        .disabled(book.appleBooksID == store.id)
                        .help("This is the book — Open in Books will open it (if you own it there, it opens; otherwise its Store page)")
                        if let page = store.url.flatMap(URL.init(string:)) {
                            Button("Store") { NSWorkspace.shared.open(page) }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Kindle").font(.subheadline.weight(.semibold))
                HStack {
                    Button("Search Kindle Store") {
                        if let url = BookLinks.search(BookLinks.kindleSearch, title: book.title, authors: book.authors) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    TextField("Paste the book\u{2019}s Amazon or Kindle link", text: $kindleLink)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(linkKindle)
                    Button("Link", action: linkKindle).disabled(kindleLink.isEmpty)
                }
                .buttonStyle(.bordered).controlSize(.small)
                if kindleProblem {
                    Text("That link names no Kindle book (no ASIN found).").font(.caption).foregroundStyle(.red)
                }
            }
            if let openCopies {
                Text("Free Copies").font(.subheadline.weight(.semibold))
                if openCopies.isEmpty {
                    Text("No open-rights copy found at Project Gutenberg or the Internet Archive.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(openCopies) { copy in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(copy.title).font(.callout).lineLimit(2)
                            Text([copy.author, copy.source].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(copy.isEPUB ? "Download to Library" : "Open") {
                            model.downloadOpenCopy(copy, for: book)
                        }
                        .disabled(model.booksStatus != nil)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private func linkKindle() {
        guard let asin = BookLinks.asin(in: kindleLink) else { kindleProblem = true; return }
        kindleProblem = false
        kindleLink = ""
        change { $0.kindleASIN = asin }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        async let store = BookLookup.appleBooks(title: book.title, authors: book.authors)
        let archive = await BookLookup.works(matching: ([book.title] + book.authors.prefix(1))
            .joined(separator: " "), limit: 1).first?.archiveID
        async let free = BookLookup.openCopies(title: book.title, authors: book.authors, archiveID: archive)
        storeBooks = await store
        openCopies = await free
    }

    // MARK: Annotations

    /// The book's annotations — W3C Web Annotations in a JSON-LD sidecar,
    /// as an EPUB's are: each on a printed page, the words there, the
    /// reader's note, or a note on the whole book.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Annotations").font(.headline)
                Spacer()
                Button("Export Annotations\u{2026}") { model.exportBookAnnotations(book) }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(annotations.isEmpty)
                    .help("Save this book\u{2019}s annotations as a W3C Web Annotation collection (JSON-LD)")
            }
            ForEach(annotations) { annotation in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppModel.printedPage(of: annotation).map { "p. \($0)" } ?? "Book")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        if let quote = annotation.quotedText {
                            Text("\u{201C}\(quote)\u{201D}").italic().foregroundStyle(.secondary)
                        }
                        if let note = annotation.body?.value { Text(note) }
                    }
                    .textSelection(.enabled)
                    Spacer()
                    Button {
                        let before = annotations
                        model.saveBookAnnotations(before.filter { $0.id != annotation.id },
                                                  previous: before, for: book)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete this annotation")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Page", text: $notePage).frame(width: 60)
                    TextField("The words on the page (optional)", text: $notePassage)
                }
                HStack {
                    TextField("Your note \u{2014} with no page, it is about the whole book", text: $noteText)
                        .onSubmit(addNote)
                    Button("Add", action: addNote)
                        .disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty
                                  && notePassage.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
        .task(id: "\(book.id)|\(model.annotationsStamp)") {
            annotations = model.bookAnnotations(book)
        }
    }

    private func addNote() {
        guard let annotation = AppModel.bookAnnotation(page: notePage, passage: notePassage, note: noteText,
                                                       source: book.annotationSource,
                                                       creator: model.authorName) else { return }
        let before = annotations
        model.saveBookAnnotations(before + [annotation], previous: before, for: book)
        noteText = ""
        notePassage = ""
    }
}

/// A spine Origami was unsure of: its picture, what it read there, the
/// books the catalogues thought it might be — and the ways to look
/// further, for print and digital copies alike.
private struct UnsureSpineDetail: View {
    @Environment(AppModel.self) private var model
    let spine: UnsureSpine
    @State private var query = ""
    @State private var results: [BookLookup.Match]?
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Not Sure").font(.title2.weight(.semibold))
                SpineImage(spine: spine).frame(maxWidth: 560, maxHeight: 90)
                Text("Read on the spine: \u{201C}\(spine.text)\u{201D}")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let photo = spine.photoName {
                    Text("From \(photo)").font(.caption2).foregroundStyle(.tertiary)
                }
                HStack {
                    TextField("Title, author or ISBN", text: $query).onSubmit { Task { await search() } }
                        .textFieldStyle(.roundedBorder)
                    Button("Search") { Task { await search() } }.disabled(query.isEmpty || searching)
                    if searching { ProgressView().controlSize(.small) }
                }
                let candidates = results ?? spine.candidates
                Text(candidates.isEmpty ? "No catalogue match yet \u{2014} search above, or look further:"
                                        : "It may be:")
                    .font(.headline)
                ForEach(candidates) { match in
                    HStack(spacing: 10) {
                        if let cover = match.coverURL.flatMap(URL.init(string:)) {
                            AsyncImage(url: cover) { $0.resizable().aspectRatio(contentMode: .fit) }
                                placeholder: { Color.secondary.opacity(0.1) }
                                .frame(width: 30, height: 45)
                        }
                        VStack(alignment: .leading) {
                            Text(match.title).font(.callout).lineLimit(2)
                            Text([match.authors.joined(separator: ", "), match.year.map(String.init) ?? "",
                                  match.source].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("This Is It") {
                            model.chooseCandidate(match, for: spine.id)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                Text("Look Further").font(.headline).padding(.top, 6)
                HStack {
                    lookButton("Apple Books", BookLinks.appleBooksSearch)
                    lookButton("Kindle Store", BookLinks.kindleSearch)
                    lookButton("Open Library", BookLinks.openLibrarySearch)
                    lookButton("Web", "https://www.google.com/search?q=")
                }
                .buttonStyle(.bordered).controlSize(.small)
                Text("Once it is in Books, its page finds it in Apple Books, Kindle, and free copies.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Not a Book", role: .destructive) { model.dismissSpine(spine.id) }
                    .buttonStyle(.borderless).font(.caption).padding(.top, 8)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .onAppear { if query.isEmpty { query = spine.text } }
    }

    private func lookButton(_ title: String, _ base: String) -> some View {
        Button(title) {
            let text = query.isEmpty ? spine.text : query
            if let url = URL(string: base + (text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let isbn = await BookLookup.book(isbn: trimmed) { results = [isbn]; return }
        results = await BookLookup.works(matching: trimmed, limit: 6)
    }
}
