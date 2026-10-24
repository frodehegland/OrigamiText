import Foundation

/// One citation record as Author keeps it in `Citations.plist` — the
/// plist shape of Author's `LACitation`, mirrored field for field so a
/// record written here reads in Author and one Author wrote reads here.
/// Origami Text's own document model carries references as BibTeX
/// (`LiquidDoc.Reference`); this type is the bridge both ways.
nonisolated struct AuthorCitation: Identifiable, Hashable, Sendable {
    /// Author's identifier: a UUID string, also the plist's key and the
    /// `[cite:id]` token the Origami exporter numbers.
    var identifier: String
    var title = ""
    /// Full names, "First Last", in order.
    var authors: [String] = []
    var year: Int?
    var month: Int?
    var day: Int?
    var doi = ""
    var webAddress = ""
    var journal = ""
    /// Where it appeared when not a journal — BibTeX's booktitle.
    var publication = ""
    var publisher = ""
    var volume = ""
    var issue = ""
    var pageRange = ""
    var isbn = ""
    var issn = ""
    var location = ""
    var editor = ""
    var series = ""
    var abstract = ""
    var annotation = ""
    var quote = ""
    var bibTeXType = "misc"
    /// The BibTeX exactly as it arrived (a paste, a lookup's answer) —
    /// the verbatim record the Origami format wants; Author keeps it in
    /// this field too.
    var originalText = ""
    var dateAccessed: Date?

    var id: String { identifier }

    init(identifier: String = UUID().uuidString) {
        self.identifier = identifier
    }

    // MARK: Plist (Author's Citations.plist entry)

    init(plist: [String: Any]) {
        identifier = (plist["identifier"] as? String) ?? UUID().uuidString
        title = Self.string("title", plist)
        if let names = plist["authors"] as? [String] {
            authors = names.filter { !$0.isEmpty }
        }
        // Author's structured names, when present, are the truth.
        if let parts = plist["citationAuthors"] as? [[String: Any]], !parts.isEmpty {
            let structured = parts.compactMap { author -> String? in
                let name = ["firstName", "middleName", "lastName"]
                    .compactMap { (author[$0] as? String)?.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return name.isEmpty ? nil : name
            }
            if !structured.isEmpty { authors = structured }
        }
        year = Self.component("yearComponent", plist)
        month = Self.component("monthComponent", plist)
        day = Self.component("dayComponent", plist)
        doi = Self.string("doi", plist)
        webAddress = Self.string("webAddress", plist)
        journal = Self.string("journal", plist)
        publication = Self.string("publication", plist)
        publisher = Self.string("publisher", plist)
        volume = Self.string("volume", plist)
        issue = Self.string("issue", plist)
        pageRange = Self.string("pageRange", plist)
        if pageRange == "0" { pageRange = "" }   // Author's placeholder
        isbn = Self.string("isbn", plist)
        issn = Self.string("issn", plist)
        location = Self.string("location", plist)
        editor = Self.string("editor", plist)
        series = Self.string("series", plist)
        abstract = Self.string("abstract", plist)
        annotation = Self.string("annotation", plist)
        quote = Self.string("quote", plist)
        let type = Self.string("bibTeXType", plist)
        bibTeXType = type.isEmpty ? "misc" : type
        originalText = Self.string("originalText", plist)
        // The Origami pasteboard's own key, when Author stored it.
        if originalText.isEmpty {
            let stored = Self.string("BibTeX", plist)
            if stored.hasPrefix("@") { originalText = stored }
        }
        dateAccessed = plist["dateAccessed"] as? Date
    }

    private static func string(_ key: String, _ plist: [String: Any]) -> String {
        ((plist[key] as? String) ?? "").trimmingCharacters(in: .whitespaces)
    }

    private static func component(_ key: String, _ plist: [String: Any]) -> Int? {
        guard let value = (plist[key] as? NSNumber)?.intValue, value > 0 else { return nil }
        return value
    }

    /// The record as Author's plist: every key Author reads, empty where
    /// unknown — Author's reader expects strings for the text fields and
    /// -1 for an absent date part.
    func plist() -> [String: Any] {
        var plist: [String: Any] = [:]
        plist["identifier"] = identifier
        plist["title"] = title
        plist["abstract"] = abstract
        plist["annotation"] = annotation
        plist["author"] = authors.first ?? ""
        plist["authors"] = authors
        plist["citationAuthors"] = authors.map { name -> [String: Any] in
            let parts = Self.nameParts(name)
            var author: [String: Any] = ["firstName": parts.first, "lastName": parts.last]
            if !parts.middle.isEmpty { author["middleName"] = parts.middle }
            return author
        }
        plist["youTubePlaybackHour"] = 0
        plist["youTubePlaybackMinute"] = 0
        plist["youTubePlaybackSecond"] = 0
        plist["dateAccessed"] = dateAccessed ?? Date()
        plist["webAddress"] = webAddress
        plist["source"] = ""
        plist["dayComponent"] = day ?? -1
        plist["yearComponent"] = year ?? -1
        plist["monthComponent"] = month ?? -1
        plist["eraComponent"] = 0
        plist["note"] = ""
        plist["keywords"] = ""
        plist["quote"] = quote
        plist["originalText"] = originalText
        plist["location"] = location
        plist["publisher"] = publisher
        plist["publication"] = publication
        plist["issue"] = issue
        plist["isbn"] = isbn
        plist["asin"] = ""
        plist["doi"] = doi
        plist["issn"] = issn
        plist["pubMed"] = ""
        plist["arXiv"] = ""
        plist["volume"] = volume
        plist["series"] = series
        plist["editor"] = editor
        plist["journal"] = journal
        plist["creationSource"] = "origamitext"
        plist["bibTeXType"] = bibTeXType
        plist["pageRangeStart"] = -1
        plist["pageRangeEnd"] = -1
        plist["pageRange"] = pageRange
        plist["filename"] = ""
        plist["hasSaved"] = true
        plist["isAnonymous"] = false
        plist["industryIdentifiers"] = [String]()
        plist["pagecited"] = ""
        plist["vm-id"] = ""
        return plist
    }

    // MARK: BibTeX

    /// A record from a BibTeX entry — a paste, a Crossref answer, a
    /// document's reference. The entry's text is kept verbatim.
    init(bibtex entry: BibTeXEntry, identifier: String = UUID().uuidString) {
        self.init(identifier: identifier)
        bibTeXType = entry.type.isEmpty ? "misc" : entry.type
        originalText = entry.raw
        let fields = entry.fields
        func field(_ key: String) -> String {
            fields[key].map(BibTeXParser.displayText)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        title = field("title")
        authors = Self.names(fromBibTeXField: fields["author"] ?? "")
        year = Int(field("year").prefix(4))
        if let monthField = fields["month"] {
            month = Int(monthField) ?? Self.monthNumber(monthField)
        }
        doi = field("doi").replacingOccurrences(of: "https://doi.org/", with: "")
        webAddress = field("url")
        journal = field("journal")
        if journal.isEmpty { journal = field("container-title") }
        publication = field("booktitle")
        if publication.isEmpty { publication = field("publication") }
        publisher = field("publisher")
        volume = field("volume")
        issue = field("number")
        pageRange = field("pages")
        isbn = field("isbn")
        issn = field("issn")
        location = field("address")
        editor = field("editor")
        series = field("series")
        abstract = field("abstract")
        annotation = field("annotation")
    }

    /// A record from the BibTeX string of an Origami reference, under
    /// that reference's id. Nil when the text is not BibTeX.
    init?(bibtexString: String, identifier: String) {
        guard let entry = BibTeXParser.first(bibtexString) else { return nil }
        self.init(bibtex: entry, identifier: identifier)
    }

    /// The record as BibTeX: verbatim when it arrived as BibTeX, else
    /// written from the fields under the record's identifier — the id is
    /// the key, so `[cite:id]` and the key agree, as the EPUB importer
    /// expects.
    var bibtex: String {
        if originalText.hasPrefix("@") { return originalText }
        var fields: [String: String] = [:]
        if !title.isEmpty { fields["title"] = title }
        if !authors.isEmpty { fields["author"] = authors.joined(separator: " and ") }
        if let year { fields["year"] = String(year) }
        if let month { fields["month"] = String(month) }
        if !journal.isEmpty { fields["journal"] = journal }
        if !publication.isEmpty { fields["booktitle"] = publication }
        if !publisher.isEmpty { fields["publisher"] = publisher }
        if !volume.isEmpty { fields["volume"] = volume }
        if !issue.isEmpty { fields["number"] = issue }
        if !pageRange.isEmpty { fields["pages"] = pageRange }
        if !doi.isEmpty { fields["doi"] = doi }
        if !webAddress.isEmpty { fields["url"] = webAddress }
        if !isbn.isEmpty { fields["isbn"] = isbn }
        if !issn.isEmpty { fields["issn"] = issn }
        if !location.isEmpty { fields["address"] = location }
        if !editor.isEmpty { fields["editor"] = editor }
        if !series.isEmpty { fields["series"] = series }
        if !abstract.isEmpty { fields["abstract"] = abstract }
        if !annotation.isEmpty { fields["annotation"] = annotation }
        return BibTeXWriter.write(type: bibTeXType, key: identifier, fields: fields)
    }

    var reference: LiquidDoc.Reference {
        LiquidDoc.Reference(id: identifier, bibtex: bibtex)
    }

    // MARK: The label in the text

    /// The surnames as Author prints them: one, "A & B", or "A et al.".
    var creatorLabel: String? {
        let surnames = authors.map { Self.nameParts($0).last }.filter { !$0.isEmpty }
        switch surnames.count {
        case 0:
            if let host = URL(string: webAddress)?.host { return host }
            return nil
        case 1: return surnames[0]
        case 2: return "\(surnames[0]) & \(surnames[1])"
        default: return "\(surnames[0]) et al."
        }
    }

    /// "Hegland 2026" — the words Author puts inside a citation's
    /// parentheses: creator then year, whichever exist.
    var attributionLabel: String {
        switch (creatorLabel, year) {
        case let (creator?, year?): return "\(creator) \(year)"
        case let (creator?, nil): return creator
        case let (nil, year?): return String(year)
        default: return title.isEmpty ? "Untitled" : title
        }
    }

    // MARK: Names

    /// "First Middle Last" split into its parts; "Last, First" accepted.
    static func nameParts(_ name: String) -> (first: String, middle: String, last: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(",") {
            let halves = trimmed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let given = halves.count > 1 ? halves[1].split(separator: " ").map(String.init) : []
            return (given.first ?? "", given.dropFirst().joined(separator: " "), halves[0])
        }
        let words = trimmed.split(separator: " ").map(String.init)
        guard words.count > 1 else { return ("", "", trimmed) }
        return (words[0], words.dropFirst().dropLast().joined(separator: " "), words[words.count - 1])
    }

    /// A BibTeX author field's names, "First Last" each: split on
    /// " and ", "Last, First" turned around, TeX accents composed.
    static func names(fromBibTeXField field: String) -> [String] {
        BibTeXParser.displayText(field)
            .components(separatedBy: " and ")
            .map { name -> String in
                let parts = nameParts(name)
                return [parts.first, parts.middle, parts.last]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }

    private static func monthNumber(_ text: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let key = text.lowercased().prefix(3)
        return names.firstIndex(of: String(key)).map { $0 + 1 }
    }
}
