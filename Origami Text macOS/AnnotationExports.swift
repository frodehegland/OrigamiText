#if os(macOS)
import AppKit
import Foundation

/// A book's annotations for other tools: Markdown (Obsidian-ready — front
/// matter, each quote with its note and tags, and a link that opens the
/// passage in Origami Text) and Readwise's CSV import format.
enum AnnotationExports {
    struct Entry {
        let quote: String?
        let note: String?
        let tags: [String]
        let link: String?
        let created: Date
        let progression: Double?
        /// The print page, when the book records its pages.
        var page: String? = nil
    }

    /// The annotations as export entries, in reading order where known.
    static func entries(_ annotations: [WebAnnotation], bookAddress: String,
                        pages: OrigamiEPUBImporter.PrintPageLocator? = nil) -> [Entry] {
        annotations.compactMap { annotation -> Entry? in
            guard annotation.motivation != WebAnnotation.Motivation.describing else { return nil }
            var quote: String?, fragment: String?, progression: Double?
            for selector in annotation.target.selectors {
                switch selector {
                case .quote(let exact, _, _): quote = quote ?? exact
                case .fragment(let value, _): fragment = fragment ?? value
                case .progression(let value): progression = progression ?? value
                default: break
                }
            }
            let isTag = annotation.motivation == WebAnnotation.Motivation.tagging
            let note = isTag ? nil : annotation.body?.value
            let tags = isTag ? [annotation.body?.value].compactMap { $0 } : []
            return Entry(quote: quote, note: note.flatMap { $0.isEmpty ? nil : $0 }, tags: tags,
                         link: fragment.flatMap { AppModel.paragraphLink(bookAddress: bookAddress, fragment: $0) },
                         created: annotation.created, progression: progression,
                         page: fragment.flatMap { pages?.page(for: $0) })
        }
        .sorted { ($0.progression ?? 2, $0.created) < ($1.progression ?? 2, $1.created) }
    }

    static func markdown(title: String, author: String, year: String?, doi: String?,
                         bookAddress: String, entries: [Entry]) -> String {
        func yaml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var lines = ["---", "title: \(yaml(title))"]
        if !author.isEmpty { lines.append("author: \(yaml(author))") }
        if let year, !year.isEmpty { lines.append("year: \(year)") }
        if let doi, !doi.isEmpty { lines.append("doi: \(yaml(doi))") }
        lines.append("source: \(yaml("origamitext://open/" + bookAddress))")
        lines.append("exported: \(ISO8601DateFormatter().string(from: .now))")
        lines += ["---", "", "# \(title)"]
        if !author.isEmpty { lines.append("*\(author)\(year.map { ", \($0)" } ?? "")*") }
        lines.append("")
        for entry in entries {
            if let quote = entry.quote {
                lines += quote.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }
            }
            if let note = entry.note { lines += ["", note] }
            var foot: [String] = []
            if !entry.tags.isEmpty {
                foot.append(entry.tags.map { "#" + $0.replacingOccurrences(of: " ", with: "-") }.joined(separator: " "))
            }
            if let page = entry.page { foot.append("p. \(page)") }
            if let link = entry.link { foot.append("[Open in Origami Text](\(link))") }
            if !foot.isEmpty { lines += ["", foot.joined(separator: " \u{00B7} ")] }
            lines += ["", "---", ""]
        }
        return lines.joined(separator: "\n")
    }

    /// Readwise's CSV: Highlight, Title, Author, URL, Note, Location, Date.
    static func readwiseCSV(title: String, author: String, entries: [Entry]) -> String {
        func cell(_ s: String?) -> String {
            let value = s ?? ""
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH:mm:ss"
        date.locale = Locale(identifier: "en_US_POSIX")
        var rows = ["Highlight,Title,Author,URL,Note,Location,Date"]
        for entry in entries {
            // Readwise needs highlighted words; a tag or note alone rides
            // as the highlight's note.
            let highlight = entry.quote ?? entry.note ?? entry.tags.first
            guard let highlight else { continue }
            var note = entry.quote == nil ? "" : (entry.note ?? "")
            if !entry.tags.isEmpty { note += (note.isEmpty ? "" : " ") + entry.tags.map { "." + $0.replacingOccurrences(of: " ", with: "-") }.joined(separator: " ") }
            rows.append([cell(highlight), cell(title), cell(author), cell(entry.link), cell(note),
                         // Readwise's Location: the print page where known.
                         cell(entry.page ?? entry.progression.map { String(Int($0 * 10000)) }),
                         cell(date.string(from: entry.created))]
                .joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

extension AppModel {
    enum AnnotationExportKind { case markdown, readwise }

    /// Saves one book's annotations as Markdown or Readwise CSV.
    func exportAnnotations(forAddress address: String, title: String, as kind: AnnotationExportKind) {
        let annotations = AnnotationStore.load(for: address, in: Self.annotationsRoot)
        let record = epubRecord(forAddress: address)
        let author = record?.author ?? ""
        let entries = AnnotationExports.entries(
            annotations, bookAddress: address,
            pages: record.map { OrigamiEPUBImporter.PrintPageLocator(folder: unpackedFolder(for: $0)) })
        guard !entries.isEmpty else {
            showNote("This book has no highlights or notes to export.")
            return
        }
        let text: String
        let fileExtension: String
        switch kind {
        case .markdown:
            text = AnnotationExports.markdown(title: title, author: author,
                                              year: record?.dateISO.map { String($0.prefix(4)) },
                                              doi: record?.doi, bookAddress: address, entries: entries)
            fileExtension = "md"
        case .readwise:
            text = AnnotationExports.readwiseCSV(title: title, author: author, entries: entries)
            fileExtension = "csv"
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title + " \u{2014} annotations." + fileExtension
        panel.canCreateDirectories = true
        panel.message = kind == .markdown
            ? "Export this book's highlights and notes as Markdown (ready for Obsidian and other notes apps)."
            : "Export this book's highlights for Readwise (import it at readwise.io/import_bulk)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showNote("Exported \(entries.count) annotation\(entries.count == 1 ? "" : "s")")
        } catch {
            showNote("Could not save the export: \(error.localizedDescription)")
        }
    }
}
#endif
