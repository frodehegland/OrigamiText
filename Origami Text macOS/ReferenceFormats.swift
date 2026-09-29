import Foundation

/// The reference-manager exchange formats beside BibTeX and CSL-JSON —
/// RIS (Zotero, Mendeley, every publisher's "Export citation"), EndNote's
/// tagged `.enw`, and EndNote XML — read into BibTeX records, the one
/// form the rest of the app carries references in. Each record keeps its
/// own key where the file states one (RIS `ID`, EndNote `%F` / label),
/// else gets a readable one: family name, year, first title word.
nonisolated enum ReferenceFormats {

    /// Whether this file is one of the kinds read here.
    static func handles(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "ris", "enw": return true
        case "xml": return isEndNoteXML(at: url)
        default: return false
        }
    }

    /// EndNote XML: `<xml><records><record>…`, which the JATS importer
    /// would otherwise refuse as "not a paper".
    static func isEndNoteXML(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return head.contains("<records") && head.contains("<record")
    }

    /// Every record in the file as BibTeX text, in file order.
    static func bibtexRecords(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "ris": return records(fromRIS: String(decoding: data, as: UTF8.self))
        case "enw": return records(fromEndNoteTagged: String(decoding: data, as: UTF8.self))
        default: return records(fromEndNoteXML: data)
        }
    }

    /// Any bibliography file the app reads — BibTeX as it is, CSL-JSON,
    /// RIS, `.enw` and EndNote XML converted — as one BibTeX text. Nil
    /// when the file is none of them or cannot be read.
    static func bibtexText(at url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "bib", "bibtex":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        case "json":
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            let items = (json as? [[String: Any]])
                ?? ((json as? [String: Any])?["items"] as? [[String: Any]]) ?? []
            guard !items.isEmpty else { return nil }
            return items.enumerated().map { position, item in
                let key = (item["id"] as? String)
                    ?? (item["id"] as? NSNumber)?.stringValue ?? "ref\(position + 1)"
                return FormatSources.bibtex(fromCSL: item, key: key)
            }.joined(separator: "\n\n")
        default:
            guard handles(url), let records = try? bibtexRecords(at: url),
                  !records.isEmpty else { return nil }
            return records.joined(separator: "\n\n")
        }
    }

    // MARK: - RIS

    /// `TY  - JOUR` … `ER  -`: a two-letter tag, two spaces, a dash.
    static func records(fromRIS text: String) -> [String] {
        var records: [String] = []
        var fields: [(String, String)] = []
        var lastTag = ""
        var usedKeys: Set<String> = []
        func close() {
            if !fields.isEmpty { records.append(bibtex(fromRISFields: fields, used: &usedKeys)) }
            fields = []
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            guard let match = line.firstMatch(of: #/^([A-Z][A-Z0-9])  -\s?(.*)$/#) else {
                // A value running onto the next line joins it.
                let continued = line.trimmingCharacters(in: .whitespaces)
                if !continued.isEmpty, let index = fields.indices.last, fields[index].0 == lastTag {
                    fields[index].1 += " " + continued
                }
                continue
            }
            let tag = String(match.1)
            let value = String(match.2).trimmingCharacters(in: .whitespaces)
            if tag == "ER" { close(); continue }
            if tag == "TY", !fields.isEmpty { close() }
            fields.append((tag, value))
            lastTag = tag
        }
        close()
        return records
    }

    private static func bibtex(fromRISFields fields: [(String, String)],
                               used: inout Set<String>) -> String {
        func all(_ tags: String...) -> [String] {
            fields.filter { tags.contains($0.0) }.map(\.1).filter { !$0.isEmpty }
        }
        func first(_ tags: String...) -> String? {
            for tag in tags { if let value = fields.first(where: { $0.0 == tag && !$0.1.isEmpty })?.1 { return value } }
            return nil
        }
        let risType = first("TY") ?? "GEN"
        let type: String = switch risType {
        case "JOUR", "JFULL", "MGZN", "NEWS", "EJOUR": "article"
        case "CONF", "CPAPER": "inproceedings"
        case "BOOK", "EBOOK", "EDBOOK": "book"
        case "CHAP", "ECHAP": "incollection"
        case "THES": "phdthesis"
        case "RPRT": "techreport"
        default: "misc"
        }
        var out: [String: String] = [:]
        let authors = all("AU", "A1")
        if !authors.isEmpty { out["author"] = authors.joined(separator: " and ") }
        let editors = all("ED", "A2").filter { _ in type == "book" || type == "incollection" }
        if !editors.isEmpty { out["editor"] = editors.joined(separator: " and ") }
        out["title"] = first("TI", "T1", "CT")
        if let container = first("T2", "JO", "JF", "JA", "BT", "J2") {
            out[type == "article" ? "journal" : "booktitle"] = container
        }
        if let date = first("PY", "Y1", "DA"),
           let year = date.firstMatch(of: #/\d{4}/#) { out["year"] = String(year.0) }
        out["volume"] = first("VL")
        out["number"] = first("IS", "CP")
        if let start = first("SP") {
            out["pages"] = first("EP").map { "\(start)--\($0)" } ?? start
        }
        out["publisher"] = first("PB")
        out["address"] = first("CY", "PP")
        out["doi"] = first("DO").map(bareDOI)
        out["url"] = first("UR", "L2")
        out["isbn"] = first("SN")
        out["abstract"] = first("AB", "N2")
        let keywords = all("KW")
        if !keywords.isEmpty { out["keywords"] = keywords.joined(separator: ", ") }
        let key = uniqueKey(first("ID"), fields: out, used: &used)
        return BibTeXWriter.write(type: type, key: key, fields: out.compactMapValues { $0 })
    }

    // MARK: - EndNote tagged (.enw)

    /// `%0 Journal Article`, `%A Author`, `%T Title` …, a blank line
    /// between records.
    static func records(fromEndNoteTagged text: String) -> [String] {
        var records: [String] = []
        var fields: [(String, String)] = []
        var used: Set<String> = []
        func close() {
            if !fields.isEmpty { records.append(bibtex(fromEndNoteFields: fields, used: &used)) }
            fields = []
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { close(); continue }
            guard line.hasPrefix("%"), line.count >= 2 else {
                if let index = fields.indices.last { fields[index].1 += " " + line }
                continue
            }
            let tag = String(line.prefix(2))
            if tag == "%0", !fields.isEmpty { close() }
            fields.append((tag, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
        }
        close()
        return records
    }

    private static func bibtex(fromEndNoteFields fields: [(String, String)],
                               used: inout Set<String>) -> String {
        func all(_ tag: String) -> [String] { fields.filter { $0.0 == tag }.map(\.1) }
        func first(_ tags: String...) -> String? {
            for tag in tags { if let value = fields.first(where: { $0.0 == tag && !$0.1.isEmpty })?.1 { return value } }
            return nil
        }
        let type = bibTeXType(forEndNote: first("%0") ?? "")
        var out: [String: String] = [:]
        let authors = all("%A")
        if !authors.isEmpty { out["author"] = authors.joined(separator: " and ") }
        let editors = all("%E")
        if !editors.isEmpty { out["editor"] = editors.joined(separator: " and ") }
        out["title"] = first("%T")
        if let container = first("%J", "%B") {
            out[type == "article" ? "journal" : "booktitle"] = container
        }
        if let date = first("%D"), let year = date.firstMatch(of: #/\d{4}/#) { out["year"] = String(year.0) }
        out["volume"] = first("%V")
        out["number"] = first("%N")
        out["pages"] = first("%P")?.replacingOccurrences(of: "-", with: "--")
        out["publisher"] = first("%I")
        out["address"] = first("%C")
        out["doi"] = first("%R").map(bareDOI)
        out["url"] = first("%U")
        out["isbn"] = first("%@")
        out["abstract"] = first("%X")
        let keywords = all("%K")
        if !keywords.isEmpty { out["keywords"] = keywords.joined(separator: ", ") }
        let key = uniqueKey(first("%F"), fields: out, used: &used)
        return BibTeXWriter.write(type: type, key: key, fields: out.compactMapValues { $0 })
    }

    private static func bibTeXType(forEndNote name: String) -> String {
        switch name.lowercased() {
        case "journal article", "magazine article", "newspaper article", "electronic article": "article"
        case "conference paper", "conference proceedings": "inproceedings"
        case "book", "edited book", "electronic book": "book"
        case "book section", "electronic book section": "incollection"
        case "thesis": "phdthesis"
        case "report": "techreport"
        default: "misc"
        }
    }

    // MARK: - EndNote XML

    static func records(fromEndNoteXML data: Data) -> [String] {
        let tree = XMLRecordTree()
        let parser = XMLParser(data: data)
        parser.delegate = tree
        parser.shouldResolveExternalEntities = false
        parser.parse()
        var used: Set<String> = []
        return tree.root?.all("record").map { record -> String in
            func text(_ path: String...) -> String? {
                var node: XMLRecordTree.Node? = record
                for name in path { node = node?.first(name) }
                return node.map(\.text).flatMap { $0.isEmpty ? nil : $0 }
            }
            let type = bibTeXType(forEndNote: record.first("ref-type")?.attributes["name"] ?? "")
            var out: [String: String] = [:]
            let authors = record.first("contributors")?.first("authors")?.all("author").map(\.text)
                .filter { !$0.isEmpty } ?? []
            if !authors.isEmpty { out["author"] = authors.joined(separator: " and ") }
            let editors = record.first("contributors")?.first("secondary-authors")?.all("author")
                .map(\.text).filter { !$0.isEmpty } ?? []
            if !editors.isEmpty { out["editor"] = editors.joined(separator: " and ") }
            out["title"] = text("titles", "title")
            if let container = text("titles", "secondary-title") ?? text("periodical", "full-title") {
                out[type == "article" ? "journal" : "booktitle"] = container
            }
            if let year = text("dates", "year")?.firstMatch(of: #/\d{4}/#) { out["year"] = String(year.0) }
            out["volume"] = text("volume")
            out["number"] = text("number")
            out["pages"] = text("pages")?.replacingOccurrences(of: "-", with: "--")
            out["publisher"] = text("publisher")
            out["address"] = text("pub-location")
            out["doi"] = text("electronic-resource-num").map(bareDOI)
            out["url"] = text("urls", "related-urls", "url")
            out["isbn"] = text("isbn")
            out["abstract"] = text("abstract")
            let keywords = record.first("keywords")?.all("keyword").map(\.text).filter { !$0.isEmpty } ?? []
            if !keywords.isEmpty { out["keywords"] = keywords.joined(separator: ", ") }
            let key = uniqueKey(text("label"), fields: out, used: &used)
            return BibTeXWriter.write(type: type, key: key, fields: out.compactMapValues { $0 })
        } ?? []
    }

    /// A small element tree over XMLParser; EndNote wraps its text in
    /// `<style>` runs, which the text simply gathers through.
    private final class XMLRecordTree: NSObject, XMLParserDelegate {
        final class Node {
            let name: String
            let attributes: [String: String]
            var children: [Node] = []
            var ownText = ""
            init(name: String, attributes: [String: String]) {
                self.name = name
                self.attributes = attributes
            }
            var text: String {
                (ownText + children.map(\.text).joined())
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func first(_ name: String) -> Node? { children.first { $0.name == name } }
            func all(_ name: String) -> [Node] {
                children.flatMap { $0.name == name ? [$0] : $0.all(name) }
            }
        }
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            let node = Node(name: elementName, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(node) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.ownText += string
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.ownText += String(decoding: CDATABlock, as: UTF8.self)
        }
    }

    // MARK: - Keys

    private static func bareDOI(_ doi: String) -> String {
        doi.replacingOccurrences(of: #"^(https?://(dx\.)?doi\.org/|doi:\s*)"#, with: "",
                                 options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }

    /// The record's own key when it states one and it is usable, else
    /// "family" + year + first title word ("nelson1965complex"), made
    /// unique within the file.
    private static func uniqueKey(_ stated: String?, fields: [String: String],
                                  used: inout Set<String>) -> String {
        func slug(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        var key = (stated ?? "").replacingOccurrences(of: #"[^A-Za-z0-9:_\-./]"#, with: "",
                                                     options: .regularExpression)
        if key.isEmpty {
            let author = fields["author"]?.components(separatedBy: " and ").first ?? ""
            let family = author.contains(",")
                ? String(author.prefix { $0 != "," })
                : String(author.split(separator: " ").last ?? "")
            let word = (fields["title"] ?? "").split(separator: " ")
                .first { $0.count > 3 }.map(String.init) ?? ""
            key = slug(family) + (fields["year"] ?? "") + slug(word)
            if key.isEmpty { key = "ref" }
        }
        var candidate = key
        var suffix = UnicodeScalar("a").value
        while used.contains(candidate), let scalar = UnicodeScalar(suffix) {
            candidate = key + String(Character(scalar))
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }
}
