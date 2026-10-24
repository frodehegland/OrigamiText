import AppKit

/// Author's paste order for the writing surface, after the library's
/// own citation flavours have had their turn: BibTeX becomes a citation,
/// a DOI is looked up on Crossref and becomes one, tab-separated text
/// becomes a table. Anything else is words.
@MainActor
enum CitationPaste {

    /// Handles the paste when it is one of the three; false lets the
    /// text through as typed.
    static func handle(_ text: String, replacing range: NSRange, controller: RichTextController) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let textView = controller.textView else { return false }

        let entries = BibTeXParser.parse(trimmed)
        if !entries.isEmpty {
            textView.setSelectedRange(range)
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    controller.insertPlain(" ", replacing: textView.selectedRange(), in: textView)
                }
                controller.insertCitation(AuthorCitation(bibtex: entry))
            }
            return true
        }

        if trimmed.count <= 240, let doi = OnlineFetch.doi(in: trimmed), isMostlyDOI(trimmed, doi: doi) {
            textView.setSelectedRange(range)
            lookUpAndInsert(doi: doi, controller: controller)
            return true
        }

        if looksTabular(trimmed) {
            controller.insertTable(tabSeparated: trimmed, replacing: range)
            return true
        }
        return false
    }

    /// The pasted text is the DOI, give or take a URL around it and
    /// trailing punctuation — not a sentence that happens to contain one.
    private static func isMostlyDOI(_ text: String, doi: String) -> Bool {
        var rest = text
        if let range = rest.range(of: doi) { rest.removeSubrange(range) }
        rest = rest.replacingOccurrences(of: #"https?://(dx\.)?doi\.org/"#, with: "", options: .regularExpression)
        rest = rest.replacingOccurrences(of: #"^\s*doi:?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return rest.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    /// Two or more lines with a tab in each, or one line with two tabs —
    /// a spreadsheet selection.
    private static func looksTabular(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        if lines.count == 1 { return lines[0].filter { $0 == "\t" }.count >= 2 }
        return lines.allSatisfy { $0.contains("\t") }
    }

    // MARK: DOI lookup

    /// A placeholder goes in at once — "(looking up 10.1145/…)" — and the
    /// record replaces it when Crossref answers. If nothing is found the
    /// DOI stays as words, so nothing pasted is ever lost.
    static func lookUpAndInsert(doi: String, controller: RichTextController) {
        guard let textView = controller.textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let token = UUID().uuidString
        var attributes = controller.baseAttributes(at: selection.location)
        attributes[AuthorAttributes.citationPlaceholder] = token
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        let placeholder = NSAttributedString(string: "(looking up \(doi)…)", attributes: attributes)
        guard textView.shouldChangeText(in: selection, replacementString: placeholder.string) else { return }
        storage.replaceCharacters(in: selection, with: placeholder)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: selection.location + placeholder.length, length: 0))
        textView.typingAttributes = controller.baseAttributes(at: selection.location)

        Task { @MainActor in
            let citation = await lookUp(doi: doi)
            guard let textView = controller.textView, let storage = textView.textStorage else { return }
            var found: NSRange?
            storage.enumerateAttribute(AuthorAttributes.citationPlaceholder,
                                       in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if (value as? String) == token { found = range; stop.pointee = true }
            }
            guard let found else { return }
            let caret = textView.selectedRange()
            textView.setSelectedRange(found)
            if let citation {
                controller.insertCitation(citation)
            } else {
                controller.insertPlain(doi, replacing: found, in: textView)
            }
            // The caret goes back where the writer left it, shifted by
            // the difference in length.
            let delta = (textView.textStorage?.length ?? 0) - storage.length
            if caret.location > NSMaxRange(found) {
                textView.setSelectedRange(NSRange(location: max(0, caret.location + delta), length: 0))
            }
        }
    }

    /// The record for a DOI, from Crossref; nil when it is not known.
    static func lookUp(doi: String) async -> AuthorCitation? {
        guard let fields = await CrossrefVerifier().lookup(fields: ["doi": doi]) else { return nil }
        var citation = AuthorCitation(bibtex: BibTeXParser.first(
            BibTeXWriter.write(type: entryType(for: fields), key: key(for: fields, doi: doi), fields: fields))
            ?? BibTeXEntry(type: "misc", key: doi, fields: fields, raw: ""))
        if citation.doi.isEmpty { citation.doi = doi }
        if citation.title.isEmpty { citation.title = doi }
        return citation
    }

    private static func entryType(for fields: [String: String]) -> String {
        if !(fields["journal"] ?? "").isEmpty { return "article" }
        if !(fields["booktitle"] ?? "").isEmpty { return "inproceedings" }
        return "misc"
    }

    /// "hegland2026" — a surname and year, the usual BibTeX key.
    private static func key(for fields: [String: String], doi: String) -> String {
        let surname = AuthorCitation.names(fromBibTeXField: fields["author"] ?? "").first
            .map { AuthorCitation.nameParts($0).last } ?? ""
        let letters = surname.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let year = fields["year"] ?? ""
        let key = String(String.UnicodeScalarView(letters)) + year
        return key.isEmpty ? doi.replacingOccurrences(of: "/", with: "-") : key
    }
}
