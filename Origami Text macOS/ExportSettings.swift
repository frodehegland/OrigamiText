import Foundation

/// What Author asks before it writes an Origami EPUB, kept with the
/// draft so the answers travel with the document and the two apps
/// agree: the header's style (Author's Plain / Basic / ACM popup), the
/// authors with their details (Author's ACM Details sheet), venue, DOI,
/// ISBN, CCS concepts, keywords and abstract (Author's Export dialog),
/// and the rights statement. Abstract, keywords and acknowledgements
/// live where Author keeps them — `Contents/exportMeta.json` — so a
/// document edited in either app shows the same; the rest sits under
/// `Author.plist["origamiExport"]`, which Author round-trips.
nonisolated struct ExportSettings: Codable, Equatable, Sendable {

    /// Author's three header styles. Plain is the title alone; Basic is
    /// the title and the authors' names; Full is the paper's front
    /// matter — affiliations, contact lines, venue and date, abstract,
    /// CCS concepts, keywords and rights (Author calls this one "ACM").
    enum FrontMatter: String, Codable, CaseIterable {
        case plain, basic, full

        var displayName: String {
            switch self {
            case .plain: "Plain"
            case .basic: "Basic"
            case .full: "Full front matter"
            }
        }

        var explanation: String {
            switch self {
            case .plain: "The title alone heads the page. Everything below is still in the record."
            case .basic: "Title and authors' names, nothing more — a letter's header."
            case .full: "Authors with affiliations and contact lines, venue and date, abstract, CCS concepts, keywords and rights — a paper's front matter."
            }
        }
    }

    /// One author as the front matter prints them (Author's ACM Details
    /// fields, one set per co-author).
    struct Author: Codable, Equatable, Identifiable {
        var id = UUID()
        var name = ""
        var email = ""
        var orcid = ""
        var institution = ""
        var city = ""
        var country = ""

        /// "Institution, City, Country" from whatever is given.
        var affiliation: String {
            [institution, city, country]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        /// The bare ORCID, whatever form it was typed in.
        var bareORCID: String {
            orcid.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^https?://(www\.)?orcid\.org/"#, with: "", options: .regularExpression)
        }

        var isEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }

        /// Two entries are the same author when their details agree —
        /// the id is the list's row identity, never written.
        static func == (lhs: Author, rhs: Author) -> Bool {
            lhs.name == rhs.name && lhs.email == rhs.email && lhs.orcid == rhs.orcid
                && lhs.institution == rhs.institution && lhs.city == rhs.city && lhs.country == rhs.country
        }

        enum CodingKeys: String, CodingKey { case name, email, orcid, institution, city, country }

        init(name: String = "", email: String = "", orcid: String = "",
             institution: String = "", city: String = "", country: String = "") {
            self.name = name
            self.email = email
            self.orcid = orcid
            self.institution = institution
            self.city = city
            self.country = country
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
            orcid = try container.decodeIfPresent(String.self, forKey: .orcid) ?? ""
            institution = try container.decodeIfPresent(String.self, forKey: .institution) ?? ""
            city = try container.decodeIfPresent(String.self, forKey: .city) ?? ""
            country = try container.decodeIfPresent(String.self, forKey: .country) ?? ""
        }
    }

    var frontMatter: FrontMatter = .basic
    var authors: [Author] = []
    /// The conference or proceedings — Author's "conference name".
    var venue = ""
    /// The journal, when the paper goes to one.
    var journal = ""
    var doi = ""
    var isbn = ""
    /// One CCS concept per entry, as printed ("Human-centered computing → Hypertext").
    var ccsConcepts: [String] = []
    /// The rights and copyright statement as the page prints it.
    var license = ""
    var licenseURI = ""
    // Kept in exportMeta.json, Author's home for them.
    var abstract = ""
    var keywords: [String] = []
    var acknowledgements = ""

    enum CodingKeys: String, CodingKey {
        case frontMatter, authors, venue, journal, doi, isbn, ccsConcepts, license, licenseURI
        case abstract, keywords, acknowledgements
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        frontMatter = try container.decodeIfPresent(FrontMatter.self, forKey: .frontMatter) ?? .basic
        authors = try container.decodeIfPresent([Author].self, forKey: .authors) ?? []
        venue = try container.decodeIfPresent(String.self, forKey: .venue) ?? ""
        journal = try container.decodeIfPresent(String.self, forKey: .journal) ?? ""
        doi = try container.decodeIfPresent(String.self, forKey: .doi) ?? ""
        isbn = try container.decodeIfPresent(String.self, forKey: .isbn) ?? ""
        ccsConcepts = try container.decodeIfPresent([String].self, forKey: .ccsConcepts) ?? []
        license = try container.decodeIfPresent(String.self, forKey: .license) ?? ""
        licenseURI = try container.decodeIfPresent(String.self, forKey: .licenseURI) ?? ""
        abstract = try container.decodeIfPresent(String.self, forKey: .abstract) ?? ""
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        acknowledgements = try container.decodeIfPresent(String.self, forKey: .acknowledgements) ?? ""
    }

    // MARK: Author's exportMeta.json

    /// The settings with abstract, keywords and acknowledgements read
    /// from Author's `exportMeta.json` dictionary — Author's edits win
    /// for the three it keeps there.
    func merging(exportMeta: [String: Any]) -> ExportSettings {
        var merged = self
        if let abstract = exportMeta["abstract"] as? String { merged.abstract = abstract }
        if let keywords = exportMeta["keywords"] as? [String] { merged.keywords = keywords }
        if let acknowledgements = exportMeta["acknowledgements"] as? String {
            merged.acknowledgements = acknowledgements
        }
        return merged
    }

    /// Author's `exportMeta.json` dictionary with these settings'
    /// abstract, keywords and acknowledgements in it; every other key
    /// (the meeting details, concepts, names) is kept as it was.
    func exportMeta(updating existing: [String: Any]) -> [String: Any] {
        var meta = existing
        meta["abstract"] = abstract
        meta["keywords"] = keywords
        meta["acknowledgements"] = acknowledgements
        if meta["concepts"] == nil { meta["concepts"] = [String]() }
        if meta["names"] == nil { meta["names"] = [String]() }
        return meta
    }

    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return nil }
        self = decoded
    }

    // MARK: Into the document

    /// The settings on a document — the fields the Origami EPUB writer
    /// prints as front matter and states in the record. Empty settings
    /// leave a field as the document had it.
    func apply(to doc: inout LiquidDoc) {
        func cleaned(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let abstract = cleaned(abstract) { doc.abstract = abstract }
        let words = keywords.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !words.isEmpty { doc.keywords = words }
        let concepts = ccsConcepts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !concepts.isEmpty { doc.ccsConcepts = concepts }
        if let venue = cleaned(venue) { doc.publication = venue }
        if let journal = cleaned(journal) { doc.journal = journal }
        if let doi = cleaned(doi) {
            doc.doi = doi.replacingOccurrences(of: #"^(https?://(dx\.)?doi\.org/|doi:\s*)"#, with: "",
                                               options: [.regularExpression, .caseInsensitive])
        }
        if let isbn = cleaned(isbn) { doc.isbn = isbn }
        if let license = cleaned(license) { doc.license = license }
        if let licenseURI = cleaned(licenseURI) { doc.licenseURI = licenseURI }

        let named = authors.filter { !$0.isEmpty }
        guard !named.isEmpty else { return }
        doc.authors = named.map { $0.name.trimmingCharacters(in: .whitespaces) }
        var affiliations: [String] = []
        for author in named {
            let name = author.name.trimmingCharacters(in: .whitespaces)
            let affiliation = author.affiliation
            if !affiliation.isEmpty {
                doc.authorAffiliations[name] = affiliation
                if !affiliations.contains(affiliation) { affiliations.append(affiliation) }
            }
            let email = author.email.trimmingCharacters(in: .whitespaces)
            if !email.isEmpty { doc.authorEmails[name] = email }
            let orcid = author.bareORCID
            if !orcid.isEmpty { doc.authorORCIDs[name] = orcid }
        }
        if !affiliations.isEmpty { doc.affiliations = affiliations }
    }

    /// Settings for a document that has none yet: the document's author
    /// as the first author, with what Settings knows of them.
    static func defaults(author: String, orcid: String, affiliation: String) -> ExportSettings {
        var settings = ExportSettings()
        var first = Author(name: author, orcid: orcid)
        // "Institution, City, Country" as Settings may already phrase it.
        let parts = affiliation.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            first.institution = parts.dropLast(2).joined(separator: ", ")
            first.city = parts[parts.count - 2]
            first.country = parts[parts.count - 1]
        } else {
            first.institution = affiliation
        }
        if !author.isEmpty { settings.authors = [first] }
        return settings
    }
}
