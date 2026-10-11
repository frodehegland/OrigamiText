import AppKit
import Foundation

/// Books: what the reader has, in every form, and the ways to fill it —
/// a shelf photographed, a book added by ISBN or title, the library's
/// own EPUBs of books — and to open each where it lives.
extension AppModel {

    // MARK: The list

    /// Every book shown in Books: the entries, and the library's EPUBs
    /// that are books with no entry yet (their ids "library:<folder>").
    var booksShown: [BookEntry] {
        let linked = Set(booksState.books.compactMap(\.libraryFolder))
        let fromLibrary = epubRecords
            .filter { Self.isLibraryBook($0) && !linked.contains($0.folder) }
            .map { record in
                BookEntry(id: "library:" + record.folder, title: record.title,
                          authors: record.authorList,
                          year: record.dateISO.flatMap { Int($0.prefix(4)) },
                          libraryFolder: record.folder, added: record.openedAt,
                          source: "Library")
            }
        return booksState.books + fromLibrary
    }

    var unsureSpines: [UnsureSpine] { booksState.unsure }

    /// A library EPUB that is a book, not a paper: its package names an
    /// ISBN, or it came from an open-rights library.
    static func isLibraryBook(_ record: EPUBRecord) -> Bool {
        guard !record.isLetter, record.dialogue == nil else { return false }
        let identifier = (record.packageIdentifier ?? "").lowercased()
        return identifier.contains("isbn")
            || identifier.range(of: #"97[89]\d{10}"#, options: .regularExpression) != nil
            || identifier.contains("gutenberg") || identifier.contains("standardebooks")
    }

    func book(withID id: String) -> BookEntry? {
        booksShown.first { $0.id == id }
    }

    func libraryRecord(for book: BookEntry) -> EPUBRecord? {
        book.libraryFolder.flatMap { folder in epubRecords.first { $0.folder == folder } }
    }

    // MARK: Finding

    /// The foot Find's rule for every list of names: each word typed
    /// begins a word of the row (diacritics and case aside). An empty
    /// Find shows everything.
    func matchesFind(_ text: String) -> Bool {
        let words = BookLookup.words(searchText)
        guard !words.isEmpty else { return true }
        let haystack = BookLookup.words(text)
        return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
    }

    // MARK: Changing it

    /// Saves a book: a library book shown without an entry becomes one.
    @discardableResult
    func updateBook(_ book: BookEntry) -> BookEntry {
        var book = book
        if book.id.hasPrefix("library:") {
            let shownID = book.id
            book.id = UUID().uuidString
            if selectedBookID == shownID { selectedBookID = book.id }
        }
        if let index = booksState.books.firstIndex(where: { $0.id == book.id }) {
            booksState.books[index] = book
        } else {
            booksState.books.append(book)
        }
        if book.isHeld {
            crossOffAcquisitions(title: book.title, authors: book.authors, doi: nil)
        }
        saveBooks()
        return book
    }

    // MARK: Annotations

    /// Books' annotation sidecars — W3C Web Annotation collections, as
    /// EPUBs' are — beside the books file.
    static var bookAnnotationsFolder: URL {
        BooksFile.localFolder.appendingPathComponent("Annotations", isDirectory: true)
    }

    func bookAnnotations(_ book: BookEntry) -> [WebAnnotation] {
        AnnotationStore.load(for: book.annotationAddress, in: Self.bookAnnotationsFolder)
    }

    /// One note on a book with no file: a printed page and the words
    /// there, the reader's note, or both. A note on no page is about the
    /// whole book (describing); words with no note are a highlight.
    static func bookAnnotation(page: String, passage: String, note: String,
                               source: String, creator: String?) -> WebAnnotation? {
        let page = page.trimmingCharacters(in: .whitespaces)
        let passage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty || !passage.isEmpty else { return nil }
        var selectors: [WebAnnotation.Selector] = []
        if !page.isEmpty {
            selectors.append(.fragment(value: page, conformsTo: BookEntry.printPageConformsTo))
        }
        if !passage.isEmpty { selectors.append(.quote(exact: passage, prefix: nil, suffix: nil)) }
        let motivation: String
        var body: WebAnnotation.TextualBody?
        if note.isEmpty {
            motivation = WebAnnotation.Motivation.highlighting
        } else if selectors.isEmpty {
            motivation = WebAnnotation.Motivation.describing
            body = .init(value: note, purpose: WebAnnotation.Motivation.describing)
        } else {
            motivation = WebAnnotation.Motivation.commenting
            body = .init(value: note)
        }
        return WebAnnotation(motivation: motivation,
                             creator: creator.flatMap { $0.isEmpty ? nil : WebAnnotation.Person(name: $0) },
                             body: body,
                             target: .init(source: source, selectors: selectors))
    }

    /// The page a book annotation stands on, when it names one.
    static func printedPage(of annotation: WebAnnotation) -> String? {
        for selector in annotation.target.selectors {
            if case .fragment(let value, let conformsTo) = selector,
               conformsTo == BookEntry.printPageConformsTo { return value }
        }
        return nil
    }

    /// Writes a book's sidecar and shares it through the community
    /// folder, merged per annotation as EPUBs' are (newest wins, a
    /// deletion newer than a note removes it). A library book shown
    /// without an entry becomes one first, so its sidecar has a name.
    /// Returns the book as saved.
    @discardableResult
    func saveBookAnnotations(_ annotations: [WebAnnotation], previous: [WebAnnotation],
                             for book: BookEntry) -> BookEntry {
        var book = book
        if book.id.hasPrefix("library:") { book = updateBook(book) }
        var annotations = annotations
        for index in annotations.indices { annotations[index].target.source = book.annotationSource }
        let address = book.annotationAddress
        let local = Self.bookAnnotationsFolder
        if !AnnotationStore.save(annotations, for: address, in: local) {
            showNote("Could not save the notes on \u{201C}\(book.title)\u{201D}")
        }
        let now = Date()
        var tombstones = annotationTombstones(for: address)
        for removed in Set(previous.map(\.id)).subtracting(annotations.map(\.id)) { tombstones[removed] = now }
        setAnnotationTombstones(tombstones, for: address)
        bumpAnnotationsStamp()
        guard let community = index.folderURL else { return book }
        let url = AnnotationSync.url(forBookFolder: address, in: community)
        let all = annotations
        Task.detached(priority: .utility) {
            let scoped = community.startAccessingSecurityScopedResource()
            defer { if scoped { community.stopAccessingSecurityScopedResource() } }
            let remote = AnnotationSync.read(url) ?? .init(annotations: [], deleted: [:])
            let merged = AnnotationSync.merge(all, tombstones, remote.annotations, remote.deleted)
            AnnotationSync.write(.init(annotations: merged.annotations, deleted: merged.deleted), to: url)
            if Set(merged.annotations.map(\.id)) != Set(all.map(\.id)) {
                AnnotationStore.save(merged.annotations, for: address, in: local)
                await MainActor.run { self.bumpAnnotationsStamp() }
            }
        }
        return book
    }

    /// Other devices' notes on the books, merged into this Mac's sidecars.
    func adoptBookAnnotations(from community: URL) {
        let books = booksState.books.map { (address: $0.annotationAddress, tombstones: annotationTombstones(for: $0.annotationAddress)) }
        let local = Self.bookAnnotationsFolder
        Task.detached(priority: .utility) {
            let scoped = community.startAccessingSecurityScopedResource()
            defer { if scoped { community.stopAccessingSecurityScopedResource() } }
            var changed = false
            for book in books {
                let url = AnnotationSync.url(forBookFolder: book.address, in: community)
                guard let remote = AnnotationSync.read(url) else { continue }
                let mine = AnnotationStore.load(for: book.address, in: local)
                let merged = AnnotationSync.merge(mine, book.tombstones, remote.annotations, remote.deleted)
                if merged.annotations != mine {
                    AnnotationStore.save(merged.annotations, for: book.address, in: local)
                    changed = true
                }
            }
            if changed { await MainActor.run { self.bumpAnnotationsStamp() } }
        }
    }

    /// Page notes from before the sidecars, moved into them.
    func migratePageNotes() {
        for book in booksState.books where !book.notes.isEmpty {
            let moved = book.notes.compactMap { note -> WebAnnotation? in
                var annotation = Self.bookAnnotation(page: note.page, passage: "", note: note.text,
                                                     source: book.annotationSource, creator: authorName)
                annotation?.created = note.added
                return annotation
            }
            saveBookAnnotations(bookAnnotations(book) + moved, previous: bookAnnotations(book), for: book)
            var emptied = book
            emptied.notes = []
            updateBook(emptied)
        }
    }

    /// Export Annotations…: the book's sidecar as it stands.
    func exportBookAnnotations(_ book: BookEntry) {
        guard let data = AnnotationStore.exportData(for: book.annotationAddress, in: Self.bookAnnotationsFolder)
        else { showNote("\u{201C}\(book.title)\u{201D} has no notes to export yet"); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = book.title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined()
            + ".annotations.jsonld"
        panel.message = "W3C Web Annotations (JSON-LD) for \u{201C}\(book.title)\u{201D}"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            showNote("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func removeBook(_ id: String) {
        booksState.books.removeAll { $0.id == id }
        if selectedBookID == id { selectedBookID = nil }
        saveBooks()
    }

    /// A catalogue match as a book entry.
    static func bookEntry(from match: BookLookup.Match, source: String) -> BookEntry {
        BookEntry(title: match.title, authors: match.authors, year: match.year,
                  publisher: match.publisher, isbns: match.isbns,
                  openLibraryKey: match.openLibraryKey, coverURL: match.coverURL,
                  source: source)
    }

    /// The standing entry for a work, if Books holds it already.
    func existingBook(like match: BookLookup.Match) -> BookEntry? {
        booksState.books.first { book in
            if let key = match.openLibraryKey, book.openLibraryKey == key { return true }
            let wanted = EPUBAcquisitions.Wanted(id: "", title: book.title,
                                                 author: book.authors.first ?? "",
                                                 year: nil, doi: nil, added: .now)
            return Self.acquisitionMatch(wanted, title: match.title, authors: match.authors, doi: nil)
        }
    }

    /// Adds a work as a printed book on the shelf — or marks the standing
    /// entry as held in print. Returns the entry.
    @discardableResult
    func addPrintedBook(_ match: BookLookup.Match, location: String?, source: String) -> BookEntry {
        var book = existingBook(like: match) ?? Self.bookEntry(from: match, source: source)
        book.inPrint = true
        if let location, !location.isEmpty, (book.location ?? "").isEmpty { book.location = location }
        if book.coverURL == nil { book.coverURL = match.coverURL }
        if book.isbns.isEmpty { book.isbns = match.isbns }
        linkLibraryCopy(into: &book)
        updateBook(book)
        return book
    }

    /// A newly shelved EPUB that is a book an entry names: the entry
    /// gains it as its library copy.
    func linkLibraryCopy(_ record: EPUBRecord) {
        guard let index = booksState.books.firstIndex(where: { book in
            book.libraryFolder == nil && Self.acquisitionMatch(
                EPUBAcquisitions.Wanted(id: "", title: book.title, author: book.authors.first ?? "",
                                        year: nil, doi: nil, added: .now),
                title: record.title, authors: record.authorList, doi: nil)
        }) else { return }
        booksState.books[index].libraryFolder = record.folder
        saveBooks()
    }

    private func linkLibraryCopy(into book: inout BookEntry) {
        guard book.libraryFolder == nil else { return }
        let wanted = EPUBAcquisitions.Wanted(id: "", title: book.title, author: book.authors.first ?? "",
                                             year: nil, doi: nil, added: .now)
        book.libraryFolder = epubRecords.first {
            !$0.isLetter && Self.acquisitionMatch(wanted, title: $0.title, authors: $0.authorList, doi: nil)
        }?.folder
    }

    // MARK: Unsure spines

    func chooseCandidate(_ match: BookLookup.Match, for spineID: String, location: String? = nil) {
        let book = addPrintedBook(match, location: location, source: "Shelf photo")
        dismissSpine(spineID, keepSelection: true)
        selectedBookID = book.id
    }

    func dismissSpine(_ id: String, keepSelection: Bool = false) {
        if let spine = booksState.unsure.first(where: { $0.id == id }), let crop = spine.cropName {
            try? FileManager.default.removeItem(at: spineCropURL(crop))
        }
        booksState.unsure.removeAll { $0.id == id }
        if !keepSelection, selectedBookID == "unsure:" + id { selectedBookID = nil }
        saveBooks()
    }

    func spineCropURL(_ name: String) -> URL {
        let folder = BooksFile.localFolder.appendingPathComponent(BooksFile.spinesFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    // MARK: Shelf photographs

    /// Reads each photograph's spines, looks every one up, shelves the
    /// sure ones as printed books and lists the rest as unsure — with
    /// what the lookup thought they might be and the spine's picture.
    func readShelfPhotos(_ urls: [URL], location: String?) {
        guard booksStatus == nil, !urls.isEmpty else { return }
        booksStatus = "Reading the photo\u{2026}"
        Task { @MainActor in
            var added = 0, unsure = 0, known = 0
            for (photoIndex, url) in urls.enumerated() {
                let label = urls.count > 1 ? "photo \(photoIndex + 1) of \(urls.count)" : "the photo"
                booksStatus = "Reading \(label)\u{2026}"
                let runs = await Task.detached(priority: .userInitiated) { () -> [[ShelfPhotoReader.Spine]] in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return ShelfPhotoReader.spines(in: url)
                }.value
                let total = runs.reduce(0) { $0 + $1.count }
                var done = 0
                for run in runs {
                    var index = 0
                    while index < run.count {
                        var spine = run[index]
                        index += 1
                        done += 1
                        booksStatus = "Looking up spine \(done) of \(total) in \(label)\u{2026}"
                        var matches = await Self.shelfMatches(for: spine.text)
                        var sure = matches.first(where: { BookLookup.isSure($0, spine: spine.text) })
                        // Not sure alone: the band may be half a spine — its
                        // title, its author — with the other half beside it.
                        if sure == nil, index < run.count {
                            let joined = spine.text + " " + run[index].text
                            let joinedMatches = await Self.shelfMatches(for: joined)
                            if let both = joinedMatches.first(where: { BookLookup.isSure($0, spine: joined) }) {
                                sure = both
                                spine.text = joined
                                index += 1
                                done += 1
                            } else if (joinedMatches.first?.score ?? 0) > (matches.first?.score ?? 0) {
                                matches = joinedMatches
                            }
                        }
                        if let sure {
                            if existingBook(like: sure)?.inPrint == true { known += 1 } else { added += 1 }
                            addPrintedBook(sure, location: location, source: "Shelf photo")
                            // The other half of a spine already known — its
                            // author beside its title — is not a spine of its own.
                            if index < run.count {
                                let bookWords = Set(BookLookup.words(([sure.title] + sure.authors).joined(separator: " ")))
                                let next = BookLookup.words(run[index].text).filter { $0.count >= 3 }
                                if !next.isEmpty, next.allSatisfy(bookWords.contains) {
                                    index += 1
                                    done += 1
                                }
                            }
                            continue
                        }
                        // Noise — a shelf label, a price sticker — finds
                        // nothing and reads faintly; it is not listed.
                        let wordCount = BookLookup.words(spine.text).filter { $0.count >= 3 }.count
                        guard !matches.isEmpty || (spine.confidence >= 0.8 && wordCount >= 2) else { continue }
                        guard !booksState.unsure.contains(where: { $0.text == spine.text }) else { continue }
                        var entry = UnsureSpine(text: spine.text,
                                                candidates: Array(matches.filter { $0.score > 0 }.prefix(4)),
                                                photoName: url.lastPathComponent)
                        if let crop = spine.crop {
                            let name = entry.id + ".jpg"
                            if ShelfPhotoReader.saveJPEG(crop, to: spineCropURL(name)) { entry.cropName = name }
                        }
                        booksState.unsure.append(entry)
                        unsure += 1
                    }
                }
            }
            saveBooks()
            booksStatus = nil
            var parts = ["\(added) book\(added == 1 ? "" : "s") added"]
            if known > 0 { parts.append("\(known) already in Books") }
            if unsure > 0 { parts.append("\(unsure) not sure \u{2014} listed under Not Sure") }
            showNote("Shelf photo: " + parts.joined(separator: ", "))
        }
    }

    /// What the catalogues think a spine's words may be, best first.
    /// Open Library first; when it is not sure, the Apple Books Store.
    static func shelfMatches(for text: String) async -> [BookLookup.Match] {
        let query = BookLookup.words(text).prefix(12).joined(separator: " ")
        func scored(_ matches: [BookLookup.Match]) -> [BookLookup.Match] {
            matches.map { match in
                var match = match
                let (title, author) = BookLookup.score(match, spine: text)
                match.score = title + (author ? 0.25 : 0)
                return match
            }
        }
        var matches = scored(await BookLookup.works(matching: query))
        if !matches.contains(where: { BookLookup.isSure($0, spine: text) }) {
            matches += scored(await BookLookup.storeMatches(query))
        }
        return matches.sorted { $0.score > $1.score }
    }

    // MARK: Opening

    func openInAppleBooks(_ book: BookEntry) {
        if let id = book.appleBooksID, let url = BookLinks.appleBooks(id),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let page = book.appleBooksURL.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(page)
        }
    }

    /// The Kindle app when it is here to take the link; Kindle for Web
    /// otherwise.
    func openInKindle(_ book: BookEntry) {
        guard let asin = book.kindleASIN else { return }
        if let url = BookLinks.kindleApp(asin), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let web = BookLinks.kindleWeb(asin) {
            NSWorkspace.shared.open(web)
        }
    }

    func openLibraryCopy(_ book: BookEntry) {
        guard let record = libraryRecord(for: book) else { return }
        openEPUBRecord(withID: record.id)
    }

    /// Downloads an open-rights EPUB into the library and links it.
    func downloadOpenCopy(_ copy: BookLookup.OpenCopy, for book: BookEntry) {
        guard copy.isEPUB, let url = URL(string: copy.url) else {
            if let url = URL(string: copy.url) { NSWorkspace.shared.open(url) }
            return
        }
        booksStatus = "Downloading \u{201C}\(copy.title)\u{201D}\u{2026}"
        Task { @MainActor in
            defer { booksStatus = nil }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue(ReferenceStatus.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (temp, response) = try? await URLSession.shared.download(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                showNote("Could not download \u{201C}\(copy.title)\u{201D} from \(copy.source)")
                return
            }
            let safe = copy.title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.prefix(80)).epub")
            try? FileManager.default.removeItem(at: file)
            guard (try? FileManager.default.moveItem(at: temp, to: file)) != nil,
                  let record = importEPUB(at: file) else { return }
            var book = book
            book.openCopyURL = copy.url
            book.libraryFolder = record.folder
            updateBook(book)
            mirrorShelfToCommunityFolder()
            showNote("\u{201C}\(record.title)\u{201D} is in the library \u{2014} from \(copy.source)")
        }
    }

    // MARK: Storage

    /// Writes the books file here, and to the community folder so every
    /// device lists the same Books.
    func saveBooks() {
        booksState.modified = .now
        let state = booksState
        BooksFile.write(state, to: BooksFile.localFolder)
        if let folder = index.folderURL {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            BooksFile.write(state, to: folder)
        }
    }

    /// The community folder's books file, when another device wrote it
    /// since this one did.
    func adoptBooks(from folder: URL) {
        guard let shared = BooksFile.read(from: folder) else {
            // None there yet: this device's books seed it.
            if !booksState.books.isEmpty || !booksState.unsure.isEmpty {
                BooksFile.write(booksState, to: folder)
            }
            return
        }
        defer { adoptBookAnnotations(from: folder) }
        guard shared.modified > booksState.modified else { return }
        booksState = shared
        BooksFile.write(shared, to: BooksFile.localFolder)
    }
}
