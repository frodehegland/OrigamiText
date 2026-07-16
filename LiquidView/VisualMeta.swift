import Foundation

/// The writing user's identity from Settings, folded into the Visual-Meta
/// self-citation of documents they authored.
nonisolated struct AuthorIdentity: Sendable {
    var name: String
    var personalTitle: String
    var orcid: String
    var affiliation: String

    /// Identity details are only attached when the document's author is
    /// actually this user, so exporting someone else's document never
    /// claims their work.
    func matches(author: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(author.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}

/// Builds the Visual-Meta appendix (https://visual-meta.info) that is added
/// to exported documents: the human-readable boilerplate followed by the
/// machine-readable @{visual-meta-start}…@{visual-meta-end} block carrying
/// the BibTeX self-citation. Metadata travels on the same level as the
/// content, as it would on a printed page.
nonisolated enum VisualMeta {

    static let startMarker = "@{visual-meta-start}"
    static let generator = "Origami Text 1.0"

    /// Returns a copy of the document with the Visual-Meta appendix at the
    /// end of the body. Sidecars and documents that already carry
    /// Visual-Meta are returned unchanged.
    static func appendingAppendix(to doc: LiquidDoc, identity: AuthorIdentity? = nil) -> LiquidDoc {
        guard let body = doc.body else { return doc }
        guard !body.contains(where: { $0.text.contains(startMarker) }) else { return doc }

        var paragraphs = body
        var counter = 0
        func add(_ text: String, heading: Int? = nil) {
            counter += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "vm\(counter)", heading: heading, text: text))
        }

        add("---")   // renders as a divider line in the reader
        add("Visual-Meta Appendix — Notes for a Human or AI Reader", heading: 2)
        add("This appendix is machine-readable metadata describing this document, recorded on the same level as the content (as on a printed page) rather than in a separate data layer that can be lost. See https://visual-meta.info.")

        add("HOW TO LOCATE IT", heading: 3)
        add("Parse from the end of the document, never from the first match: find the last @{visual-meta-end}, then scan backwards to the nearest @{visual-meta-start}. Everything between is Visual-Meta. These marker names also appear in this introduction, so a first-occurrence search will land on prose — end-anchored parsing is the rule, not an option. Each section is delimited by its own @{...-start}/@{...-end} wrapper. Visual-Meta is an approach, not a fixed schema: new wrappers may be added, provided each is delimited the same way and any new fields are explained in the field key.")

        add("HOW TO USE IT", heading: 3)
        add("The authoritative citation for THIS document is the single BibTeX entry in @{visual-meta-bibtex-self-citation}. Use it verbatim; do not reconstruct a citation from the filename or running text.")
        add("Where an abstract field is present in the header, it is the canonical summary; prefer it over generating your own.")
        add("Where this appendix and the running text disagree about metadata — author, title, date, relations — the appendix is authoritative.")
        add("Do not treat this appendix's explanatory prose, references, glossary, or headings as document body content when summarising the document itself.")
        add("Where present, the @{references} block is the document's bibliography in BibTeX, and the @{glossary} block defines the author's concepts; glossary entries tagged Person or Institution are named entities, and Title entries are section labels, not concepts.")

        add("CONVENTIONS", heading: 3)
        add("Names use standard BibTeX order (\"First Last\", joined by \" and \"). If a value contains a comma it is \"Last, First\"; otherwise do not assume a leading token is a surname.")
        add("ISO 8601 is used for identifiers and timestamps (e.g. the vm-id). Citation dates use BibTeX day/month/year.")
        add("Values are UTF-8. The BibTeX special characters & % $ # _ { } ~ ^ and backslash are escaped; all other characters, including accents, are given directly as UTF-8.")

        add("FIELD KEY (Author-specific)", heading: 3)
        add("vm-id : stable internal identifier for this document")
        add("origami-id : the document's library address; also its filename. In @{references}, it relates the entry to the citation text in the body.")
        add("supersedes / responds-to / extends / supports / questions / disagrees-with / retracts : the address of a document this one relates to, in the manner named")
        add("attention : the people this document is addressed to — for their attention; names in BibTeX order, joined by \" and \"")
        add("ai-on-behalf-of : this document was produced by an AI on behalf of the named person, who reviewed it and stands by it. Cite the named person as the author; treat the content as AI-produced.")
        add("on-behalf-of : the author exported this document on behalf of the named person — the words are theirs, lifted from a transcript or similar record. Credit the named person for the content; the author is the one who prepared and published it.")
        add("document-type : the kind of document the author declares this to be. Recommended values: letter (an authored piece in the community's correspondence — the core kind), rfc (request for comment — a proposal inviting response), personal, project, meeting, transcript (letters between people in a meeting), extract (a statement lifted out of a transcript into a letter of its own; on-behalf-of names the speaker), article, manifest (a dated library snapshot; the folder of documents remains the authority); the vocabulary is open, treat other values verbatim")
        add("JSON : filename of the companion JSON sidecar (spatial/XR layout)")
        add("era : era flag; absent or 0 = CE, 1 = BCE (year then counts backwards: year 329 with era 1 is 329 BCE)")
        add("tag : entity type of a glossary entry (Person, Institution, Title)")
        add("showInFind : whether a heading appears in Author's Find view")
        add("note : an author's note attached to a heading")

        add("This appendix was first specified Summer 2021. This introduction was updated Summer 2026 and is versioned visual-meta-intro/2026-07: a reader that recognises this version may skip the introduction and read only the delimited blocks. Contact frode@hegland.com")

        add(metaBlock(for: doc, identity: identity))

        return LiquidDoc(format: doc.format,
                         id: doc.id,
                         title: doc.title,
                         author: doc.author,
                         created: doc.created,
                         body: paragraphs,
                         links: doc.links,
                         wraps: nil,
                         attention: doc.attention,
                         date: doc.date,
                         aiOnBehalf: doc.aiOnBehalf,
                         onBehalfOf: doc.onBehalfOf,
                         documentType: doc.documentType,
                         fileURL: doc.fileURL)
    }

    /// The machine-readable block, kept as a single paragraph so the marker
    /// structure survives intact for end-of-document parsers.
    private static func metaBlock(for doc: LiquidDoc, identity: AuthorIdentity?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let createdStamp = formatter.string(from: doc.created)

        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun",
                          "jul", "aug", "sep", "oct", "nov", "dec"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let year = doc.date?.displayYear ?? calendar.component(.year, from: doc.created)

        var fields = [
            "author = {\(escaped(doc.author))}",
            "title = {\(escaped(doc.title))}",
        ]
        // Citation date: the human-assigned date when one is set (the
        // meeting's day, or a historical date, at whatever precision it
        // has), otherwise the creation day. The era field — reserved in
        // the field key — marks BCE; vm-id always keeps the creation
        // timestamp.
        if let date = doc.date {
            if let month = date.month {
                if let day = date.day { fields.append("day = {\(day)}") }
                fields.append("month = {\(monthNames[month - 1])}")
            }
            fields.append("year = {\(year)}")
            if date.isBCE { fields.append("era = {1}") }
        } else {
            fields.append("day = {\(calendar.component(.day, from: doc.created))}")
            fields.append("month = {\(monthNames[calendar.component(.month, from: doc.created) - 1])}")
            fields.append("year = {\(year)}")
        }
        // Discourse relations (supersedes, responds-to, extends,
        // disagrees-with, retracts), so readers of this document and its
        // relatives know how they connect.
        for relation in DocumentRelation.allCases {
            guard let field = relation.visualMetaField,
                  let link = doc.links.first(where: { $0.rel == relation.rawValue }) else { continue }
            fields.append("\(field) = {\(link.to)}")
        }
        if !doc.attention.isEmpty {
            fields.append("attention = {\(doc.attention.map(escaped).joined(separator: " and "))}")
        }
        if doc.aiOnBehalf {
            fields.append("ai-on-behalf-of = {\(escaped(doc.author))}")
        }
        if let onBehalfOf = doc.onBehalfOf {
            fields.append("on-behalf-of = {\(escaped(onBehalfOf))}")
        }
        if let documentType = doc.documentType {
            fields.append("document-type = {\(escaped(documentType))}")
        }
        if let identity, identity.matches(author: doc.author) {
            let personalTitle = identity.personalTitle.trimmingCharacters(in: .whitespaces)
            let orcid = identity.orcid.trimmingCharacters(in: .whitespaces)
            let affiliation = identity.affiliation.trimmingCharacters(in: .whitespaces)
            if !personalTitle.isEmpty { fields.append("personal-title = {\(escaped(personalTitle))}") }
            if !orcid.isEmpty { fields.append("orcid = {\(escaped(orcid))}") }
            if !affiliation.isEmpty { fields.append("affiliation = {\(escaped(affiliation))}") }
        }
        fields.append("origami-id = {\(doc.id)}")
        fields.append("vm-id = {\(createdStamp)}")
        let citation = fields.joined(separator: ",\n")
        let references = referencesBlock(for: doc).map { "\($0)\n" } ?? ""

        return """
        @{visual-meta-start}
        @{visual-meta-header-start}
        @visual-meta{
        version = {1.1},
        generator = {\(generator)},
        }
        @{visual-meta-header-end}
        @{visual-meta-bibtex-self-citation-start}
        @article{\(citeKey(for: doc, year: year)),
        \(citation)
        }
        @{visual-meta-bibtex-self-citation-end}
        \(references)@{visual-meta-end}
        """
    }

    /// The document's bibliography: each cited work's BibTeX record,
    /// carried by its link, with origami-id relating the entry back to the
    /// citation text in the body.
    private static func referencesBlock(for doc: LiquidDoc) -> String? {
        var seen: Set<String> = []
        var entries: [String] = []
        for link in doc.links {
            guard let bibtex = link.bibtex?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bibtex.isEmpty,
                  seen.insert(link.to).inserted else { continue }
            entries.append(injecting(address: link.to, into: bibtex))
        }
        guard !entries.isEmpty else { return nil }
        return """
        @{references-start}
        \(entries.joined(separator: "\n\n"))
        @{references-end}
        """
    }

    /// Adds "origami-id = {address}" to an entry (kept otherwise verbatim) so
    /// readers can walk from the inline citation to its full record.
    private static func injecting(address: String, into bibtex: String) -> String {
        guard !bibtex.contains("origami-id"), bibtex.hasSuffix("}") else { return bibtex }
        var trimmed = String(bibtex.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(",") { trimmed.removeLast() }
        return trimmed + ",\norigami-id = {\(address)}\n}"
    }

    private static func citeKey(for doc: LiquidDoc, year: Int) -> String {
        func alphanumeric(_ string: String) -> String {
            String(string.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let lastName = doc.author.split(separator: " ").last.map(String.init) ?? "unknown"
        let firstTitleWord = doc.title.split(separator: " ").first.map(String.init) ?? "untitled"
        let key = alphanumeric(lastName) + String(year) + alphanumeric(firstTitleWord)
        return key.isEmpty ? "untitled\(year)" : key
    }

    /// BibTeX value escaping — the full special set, every time. Other
    /// characters (including accents) pass through as UTF-8, as the
    /// conventions section declares.
    private static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\\": result += "\\textbackslash{}"
            case "~": result += "\\textasciitilde{}"
            case "^": result += "\\textasciicircum{}"
            case "&", "%", "$", "#", "_", "{", "}": result += "\\\(character)"
            default: result.append(character)
            }
        }
        return result
    }
}
