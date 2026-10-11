import Foundation

/// A book the reader has, in whatever form: on a shelf in print, in Apple
/// Books, in Kindle, as an open-rights copy, or as an EPUB in the library
/// — often several at once. Books lists them; a library EPUB that is a
/// book shows there too. A book with no file is a reference to the work,
/// with the ways to open it where it lives.
nonisolated struct BookEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var authors: [String] = []
    var year: Int?
    var publisher: String?
    var isbns: [String] = []
    /// Open Library's work key ("/works/OL…W") — the cover and editions.
    var openLibraryKey: String?
    var coverURL: String?

    /// A copy on paper, and where it stands ("study, top shelf", "lent
    /// to Mark").
    var inPrint = false
    var location: String?
    /// The Apple Books Store id — `ibooks://assetid/<id>` opens it.
    var appleBooksID: String?
    var appleBooksURL: String?
    /// The Kindle ASIN — `kindle://book?action=open&asin=<asin>`.
    var kindleASIN: String?
    /// A free, open-rights copy (Project Gutenberg, the Internet Archive).
    var openCopyURL: String?
    /// The library's own EPUB of it, by community file name
    /// (EPUBRecord.folder — the name every device agrees on).
    var libraryFolder: String?

    /// Notes written before books had annotation sidecars — moved into
    /// the sidecar (`AppModel.migratePageNotes`) and emptied.
    var notes: [PageNote] = []
    var added = Date.now
    /// How it came: "Shelf photo", "Added by hand", "Library".
    var source: String?

    /// The book's name in its annotations' `target.source`, as an EPUB's
    /// sidecar names it by DOI or ISBN: its ISBN (13 digits preferred),
    /// else its Open Library work, else this entry.
    var annotationSource: String {
        let isbns = isbns.map { $0.uppercased().filter { $0.isNumber || $0 == "X" } }
        if let isbn = isbns.first(where: { $0.count == 13 }) ?? isbns.first(where: { $0.count == 10 }) {
            return "urn:isbn:" + isbn
        }
        if let key = openLibraryKey { return "https://openlibrary.org" + key }
        return "urn:origami:book:" + id
    }

    /// The sidecar's address: `book-<id>.annotations.jsonld`, beside the
    /// books file, and `_annotations/book-<id>.json` in the community
    /// folder — the same two homes an EPUB's annotations have.
    var annotationAddress: String { "book-" + id }

    /// What a printed page's FragmentSelector conforms to: its value is
    /// the page as printed ("112", "xiv").
    static let printPageConformsTo = "https://origamitext.app/ns/print-page"

    struct PageNote: Codable, Identifiable, Hashable, Sendable {
        var id = UUID().uuidString
        /// The printed page ("p. 112", "xiv") — a book without a file has
        /// no paragraphs to anchor to.
        var page: String
        var text: String
        var added = Date.now
    }

    var authorLine: String { authors.joined(separator: ", ") }

    /// Holds the work in some form — enough to cross it off To Acquire.
    var isHeld: Bool {
        inPrint || appleBooksID != nil || kindleASIN != nil
            || openCopyURL != nil || libraryFolder != nil
    }
}

/// A spine a shelf photograph showed but Origami could not be sure of:
/// what it read there, the crop of the spine itself, and the books the
/// lookup thought it might be.
nonisolated struct UnsureSpine: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var text: String
    /// The spine's picture, saved beside the books file (Book Spines/).
    var cropName: String?
    var candidates: [BookLookup.Match] = []
    var added = Date.now
    var photoName: String?
}

/// The books file: the entries, and the spines still unsure. One small
/// file in the community folder so every device lists the same Books;
/// kept in Application Support as well, so Books works without one.
nonisolated enum BooksFile {
    struct State: Codable, Sendable {
        var books: [BookEntry] = []
        var unsure: [UnsureSpine] = []
        var modified: Date = .distantPast
    }

    static let fileName = "origami-books.json"
    static let spinesFolder = "Book Spines"

    static var localFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func read(from folder: URL) -> State? {
        let url = folder.appendingPathComponent(fileName)
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    static func write(_ state: State, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        let url = folder.appendingPathComponent(fileName)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { writeURL in
            try? data.write(to: writeURL, options: .atomic)
        }
    }
}

/// The ways to open a book where it lives.
nonisolated enum BookLinks {
    static func appleBooks(_ id: String) -> URL? { URL(string: "ibooks://assetid/\(id)") }
    static func kindleApp(_ asin: String) -> URL? { URL(string: "kindle://book?action=open&asin=\(asin)") }
    /// Kindle for Web — always there, whether or not the Kindle app is.
    static func kindleWeb(_ asin: String) -> URL? { URL(string: "https://read.amazon.com/?asin=\(asin)") }

    /// The ASIN in an Amazon or Kindle link the reader pasted —
    /// /dp/…, /gp/product/…, asin=…, or the bare ten characters.
    static func asin(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil { return trimmed }
        for pattern in [#"/dp/([A-Z0-9]{10})"#, #"/gp/product/([A-Z0-9]{10})"#,
                        #"[?&]asin=([A-Z0-9]{10})"#, #"/product/([A-Z0-9]{10})"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return trimmed[range].uppercased()
            }
        }
        return nil
    }

    /// Searches for a book by its title and author.
    static func search(_ base: String, title: String, authors: [String]) -> URL? {
        let query = ([title] + authors.prefix(1)).joined(separator: " ")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: base + query)
    }
    static let kindleSearch = "https://www.amazon.com/s?i=digital-text&k="
    static let appleBooksSearch = "https://books.apple.com/search?term="
    static let openLibrarySearch = "https://openlibrary.org/search?q="
}

/// What the open catalogues know of a book: Open Library and Google Books
/// for the work, the Apple Books Store for its ebook, and Project
/// Gutenberg (through Gutendex) and the Internet Archive for free copies.
/// No keys; one polite request at a time.
nonisolated enum BookLookup {

    struct Match: Codable, Hashable, Sendable, Identifiable {
        var id: String { (openLibraryKey ?? "") + "|" + title + "|" + authors.joined(separator: ",") }
        var title: String
        var authors: [String]
        var year: Int?
        var publisher: String?
        var isbns: [String] = []
        var openLibraryKey: String?
        var coverURL: String?
        /// The Internet Archive item when the work is public there.
        var archiveID: String?
        /// How well the spine's words cover this title (0…1).
        var score: Double = 0
        var source: String
    }

    struct StoreBook: Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var author: String
        var url: String?
        var artwork: String?
        var price: String?
    }

    struct OpenCopy: Hashable, Sendable, Identifiable {
        var id: String { url }
        var title: String
        var author: String
        var url: String
        var source: String
        /// Downloadable as an EPUB straight into the library.
        var isEPUB: Bool
    }

    private static func json(_ url: URL, timeout: TimeInterval = 20) async -> Any? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(ReferenceStatus.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }

    /// The works a free-text query (a spine's words, or what the reader
    /// typed) may be — Open Library first, Google Books after.
    static func works(matching query: String, limit: Int = 5) async -> [Match] {
        var matches: [Match] = []
        let fields = "key,title,author_name,first_publish_year,isbn,cover_i,publisher,ebook_access,ia"
        if let url = URL(string: "https://openlibrary.org/search.json?q=\(encoded(query))&fields=\(fields)&limit=\(limit)"),
           let object = await json(url) as? [String: Any],
           let docs = object["docs"] as? [[String: Any]] {
            for doc in docs {
                guard let title = doc["title"] as? String else { continue }
                let cover = (doc["cover_i"] as? Int).map { "https://covers.openlibrary.org/b/id/\($0)-M.jpg" }
                let isPublic = (doc["ebook_access"] as? String) == "public"
                matches.append(Match(title: title,
                                     authors: doc["author_name"] as? [String] ?? [],
                                     year: doc["first_publish_year"] as? Int,
                                     publisher: (doc["publisher"] as? [String])?.first,
                                     isbns: Array((doc["isbn"] as? [String] ?? []).prefix(6)),
                                     openLibraryKey: doc["key"] as? String,
                                     coverURL: cover,
                                     archiveID: isPublic ? (doc["ia"] as? [String])?.first : nil,
                                     source: "Open Library"))
            }
        }
        if matches.count < 2,
           let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=\(encoded(query))&maxResults=\(limit)&printType=books"),
           let object = await json(url) as? [String: Any],
           let items = object["items"] as? [[String: Any]] {
            for item in items {
                guard let info = item["volumeInfo"] as? [String: Any],
                      let title = info["title"] as? String else { continue }
                let subtitle = info["subtitle"] as? String
                let isbns = (info["industryIdentifiers"] as? [[String: Any]] ?? [])
                    .compactMap { $0["identifier"] as? String }
                let year = (info["publishedDate"] as? String).flatMap { Int($0.prefix(4)) }
                let cover = ((info["imageLinks"] as? [String: Any])?["thumbnail"] as? String)?
                    .replacingOccurrences(of: "http://", with: "https://")
                matches.append(Match(title: subtitle.map { "\(title): \($0)" } ?? title,
                                     authors: info["authors"] as? [String] ?? [],
                                     year: year,
                                     publisher: info["publisher"] as? String,
                                     isbns: isbns, coverURL: cover,
                                     source: "Google Books"))
            }
        }
        return matches
    }

    /// The Apple Books Store's ebooks as catalogue matches — edition
    /// titles, where Open Library files a renamed book under its first
    /// ("The Design of Everyday Things" stands as "The Psychology of…").
    static func storeMatches(_ text: String) async -> [Match] {
        await appleBooks(title: text, authors: []).map { store in
            Match(title: store.title, authors: [store.author], coverURL: store.artwork,
                  source: "Apple Books Store")
        }
    }

    /// The book by ISBN, for Add Book.
    static func book(isbn: String) async -> Match? {
        let digits = isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard digits.count == 10 || digits.count == 13 else { return nil }
        return await works(matching: "isbn:\(digits)", limit: 1).first
    }

    /// The Apple Books Store's ebooks of a work.
    static func appleBooks(title: String, authors: [String]) async -> [StoreBook] {
        let term = ([title] + authors.prefix(1)).joined(separator: " ")
        guard let url = URL(string: "https://itunes.apple.com/search?media=ebook&entity=ebook&limit=6&term=\(encoded(term))"),
              let object = await json(url) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { result in
            guard let id = result["trackId"] as? Int,
                  let name = result["trackName"] as? String else { return nil }
            return StoreBook(id: String(id), title: name,
                             author: result["artistName"] as? String ?? "",
                             url: result["trackViewUrl"] as? String,
                             artwork: result["artworkUrl100"] as? String,
                             price: result["formattedPrice"] as? String)
        }
    }

    /// Free copies: Project Gutenberg's EPUBs, and the Internet Archive's
    /// public item when Open Library named one.
    static func openCopies(title: String, authors: [String], archiveID: String?) async -> [OpenCopy] {
        var copies: [OpenCopy] = []
        let surname = authors.first?.split(separator: " ").last.map(String.init) ?? ""
        // The trailing slash: Gutendex redirects without it, slowly.
        if let url = URL(string: "https://gutendex.com/books/?search=\(encoded([title, surname].joined(separator: " ")))"),
           let object = await json(url, timeout: 60) as? [String: Any],
           let results = object["results"] as? [[String: Any]] {
            for result in results.prefix(4) {
                guard let name = result["title"] as? String,
                      let formats = result["formats"] as? [String: String] else { continue }
                let author = ((result["authors"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
                if let epub = formats.first(where: { $0.key.hasPrefix("application/epub+zip") })?.value {
                    copies.append(OpenCopy(title: name, author: author, url: epub,
                                           source: "Project Gutenberg", isEPUB: true))
                }
            }
        }
        if let archiveID {
            copies.append(OpenCopy(title: title, author: authors.first ?? "",
                                   url: "https://archive.org/details/\(archiveID)",
                                   source: "Internet Archive", isEPUB: false))
        }
        return copies
    }

    // MARK: Judging a spine

    /// Words only, lowercased, diacritics folded.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static let minor: Set<String> = ["the", "a", "an", "of", "and", "in", "on", "to",
                                             "for", "with", "at", "by", "from", "de", "la", "le"]

    /// How much of a match's title the spine's words carry, with a nudge
    /// when its author's surname is there too: the measure of sure.
    static func score(_ match: Match, spine: String) -> (title: Double, author: Bool) {
        let spineWords = Set(words(spine))
        let titleWords = words(match.title.components(separatedBy: ":").first ?? match.title)
            .filter { !minor.contains($0) }
        guard !titleWords.isEmpty else { return (0, false) }
        let found = titleWords.filter { word in
            spineWords.contains(word) || spineWords.contains { $0.count >= 5 && word.hasPrefix($0) }
        }
        let author = match.authors.contains { name in
            guard let surname = words(name).last, surname.count >= 3 else { return false }
            return spineWords.contains(surname)
        }
        return (Double(found.count) / Double(titleWords.count), author)
    }

    /// A spine is sure when its words carry the whole title (or nearly)
    /// and either the author too or a title long enough to be its own.
    static func isSure(_ match: Match, spine: String) -> Bool {
        let (title, author) = score(match, spine: spine)
        let length = words(match.title).filter { !minor.contains($0) }.count
        return title >= 0.85 && (author || length >= 3)
    }
}
