// WHERE HAVE I READ THIS? — a phrase, lifted from anywhere, found in
// everything you have read. Select a sentence in any app (a mail, a
// web page, a colleague's draft), ask this, and the answer is the
// paper it came from, the section, and the place — opened at the very
// paragraph.
//
// The Liquid principle, turned on one's own reading: the app one is in
// does not matter, and the text one is holding has usually lost its
// source. This gives it back.
//
// Two libraries answer, by the reader's own choosing (Settings ▸
// Finding): the Origami library this app indexes — Origami documents
// and every EPUB on the shelf — and, when a folder is named, the PDFs
// in Reader's library, read with PDFKit. A hit in a PDF opens the file
// and says its page; a hit in a document opens the reading at the
// paragraph.
#if os(macOS)
import SwiftUI
import AppKit
import PDFKit

// MARK: - What a search finds

/// One place a phrase was read: which document, where in it, and the
/// words around it.
struct ReadingHit: Identifiable, Hashable {
    enum Home: Hashable {
        /// An Origami document or a shelf EPUB — the index knows it.
        case library(docID: String, paragraphID: String)
        /// A PDF in Reader's library, at a page (1-based, as a reader counts).
        case pdf(url: URL, page: Int)
    }

    let id = UUID()
    let home: Home
    let title: String
    let author: String
    /// The heading the hit sits under, when there is one.
    let section: String?
    /// The sentence (or thereabouts) carrying the phrase.
    let passage: String
    /// The range of the phrase within `passage`, for painting it.
    let matchRange: Range<String.Index>?
    /// Exact phrase, or every word present but scattered.
    let isExact: Bool

    var placeDescription: String {
        switch home {
        case .library: section ?? ""
        case .pdf(_, let page): section.map { "\($0) · page \(page)" } ?? "page \(page)"
        }
    }

    var isPDF: Bool {
        if case .pdf = home { return true }
        return false
    }
}

// MARK: - The settings

enum ReadingSearchSettings {
    /// The Origami library — documents and shelf EPUBs. On by default;
    /// a toggle rather than an assumption, because a reader who only
    /// wants their PDFs searched should be able to say so.
    static let searchesLibraryKey = "findInReading.searchesLibrary"
    /// Reader's PDFs — the Reader Library the app already knows
    /// (Settings ▸ Library), whose security scope AppModel holds open
    /// for citation resolving. This searches the same folder rather
    /// than asking for a second one: one Reader library, one answer to
    /// where it is.
    static let searchesPDFsKey = "findInReading.searchesPDFs"

    static var searchesLibrary: Bool {
        get { UserDefaults.standard.object(forKey: searchesLibraryKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: searchesLibraryKey) }
    }
    /// On by default: a reader who has told the app where Reader keeps
    /// its papers means for them to count as their reading. It is a
    /// toggle all the same — a big PDF library is seconds of work, and
    /// some will want the library alone.
    static var searchesPDFs: Bool {
        get { UserDefaults.standard.object(forKey: searchesPDFsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: searchesPDFsKey) }
    }
}

// MARK: - The search itself

/// The phrase finder. The library is searched on the main actor (the
/// index lives there and the work is a string comparison); the PDFs go
/// to a detached task, because reading a hundred files is seconds, not
/// milliseconds, and the panel must stay alive while it happens.
@MainActor @Observable
final class ReadingSearch {
    private(set) var phrase = ""
    private(set) var hits: [ReadingHit] = []
    private(set) var isSearching = false
    /// What was searched, said plainly under the results — a reader
    /// who forgot they turned PDFs off should not conclude the paper
    /// does not exist.
    private(set) var scopeNote = ""
    private var generation = 0

    /// How much text a hit shows around the phrase. Nonisolated, both
    /// of these: the PDF sweep reads them off the main actor, and a
    /// main-actor constant there is a Swift 6 error.
    nonisolated private static let passageRadius = 140
    /// A guard against a runaway sweep of someone's whole disk.
    nonisolated private static let pdfFileLimit = 2_000

    func clear() {
        phrase = ""
        hits = []
        scopeNote = ""
        isSearching = false
        generation += 1
    }

    /// The whole act: normalise the phrase, ask each chosen library,
    /// and publish the hits as they come.
    func run(_ raw: String, in model: AppModel) {
        generation += 1
        let mine = generation
        let needle = Self.normalised(raw)
        phrase = Self.tidyForDisplay(raw)
        hits = []
        guard needle.count >= 3 else {
            scopeNote = "Ask with a few more words — three letters find everything."
            isSearching = false
            return
        }
        isSearching = true

        var notes: [String] = []
        if ReadingSearchSettings.searchesLibrary {
            let found = Self.searchLibrary(needle: needle, model: model)
            hits = found
            notes.append("\(model.index.byID.count) documents")
        }

        guard ReadingSearchSettings.searchesPDFs else {
            scopeNote = Self.note(notes, pdfs: nil)
            isSearching = false
            return
        }
        // Reader's own library, as Settings ▸ Library names it. Its
        // security scope is already held open by AppModel for citation
        // resolving, so nothing is asked of the reader here.
        guard let folder = model.readerLibraryURL else {
            scopeNote = Self.note(notes, pdfs: nil)
                + " Reader's library is not set — name it in Settings ▸ Library to search your PDFs too."
            isSearching = false
            return
        }

        Task.detached(priority: .userInitiated) {
            let found = Self.searchPDFs(needle: needle, folder: folder)
            await MainActor.run {
                guard mine == self.generation else { return }
                self.hits += found.hits
                notes.append("\(found.filesRead) PDFs")
                self.scopeNote = Self.note(notes, pdfs: found.filesRead)
                self.isSearching = false
            }
        }
    }

    private static func note(_ parts: [String], pdfs: Int?) -> String {
        parts.isEmpty
            ? "Nothing is being searched — choose what to look in, in Settings ▸ Finding."
            : "Searched " + parts.joined(separator: " and ") + "."
    }

    // MARK: The library

    private static func searchLibrary(needle: String, model: AppModel) -> [ReadingHit] {
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        var exact: [ReadingHit] = []
        var loose: [ReadingHit] = []
        for entry in model.index.byID.values {
            let doc = entry.doc
            var currentSection: String?
            for paragraph in doc.body ?? [] {
                if paragraph.effectiveHeading != nil {
                    currentSection = paragraph.text
                    continue
                }
                let hay = normalised(paragraph.text)
                guard !hay.isEmpty else { continue }
                if let range = hay.range(of: needle) {
                    exact.append(hit(doc: doc, paragraph: paragraph, section: currentSection,
                                     hay: hay, range: range, isExact: true))
                } else if words.count > 1, words.allSatisfy({ hay.contains($0) }),
                          let first = words.compactMap({ hay.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                    loose.append(hit(doc: doc, paragraph: paragraph, section: currentSection,
                                     hay: hay, range: first, isExact: false))
                }
            }
        }
        // Exact readings first; a scattering of the same words after.
        return exact.sorted { $0.title < $1.title } + loose.sorted { $0.title < $1.title }
    }

    private static func hit(doc: LiquidDoc, paragraph: LiquidDoc.Paragraph,
                            section: String?, hay: String,
                            range: Range<String.Index>, isExact: Bool) -> ReadingHit {
        let (passage, matched) = passage(in: hay, around: range)
        return ReadingHit(
            home: .library(docID: doc.id, paragraphID: paragraph.id),
            title: doc.title,
            author: doc.displayAuthor,
            section: section,
            passage: passage,
            matchRange: matched,
            isExact: isExact)
    }

    // MARK: Reader's PDFs

    nonisolated private static func searchPDFs(needle: String, folder: URL)
        -> (hits: [ReadingHit], filesRead: Int) {
        // The scope is AppModel's to hold and to drop — this only reads.
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], 0) }

        var hits: [ReadingHit] = []
        var read = 0
        for case let url as URL in walker where url.pathExtension.lowercased() == "pdf" {
            guard read < pdfFileLimit else { break }
            read += 1
            autoreleasepool {
                guard let document = PDFDocument(url: url) else { return }
                // PDFKit's own finder does the page walk in C; it is far
                // faster than pulling every page's string into Swift.
                let found = document.findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive])
                guard !found.isEmpty else { return }
                let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
                    .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                    ?? url.deletingPathExtension().lastPathComponent
                let author = (document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) ?? ""
                // One hit per file: a phrase found six times in one paper
                // is one answer to "where did I read this", not six.
                guard let selection = found.first, let page = selection.pages.first else { return }
                let number = document.index(for: page) + 1
                let pageText = normalised(page.string ?? "")
                let range = pageText.range(of: normalised(needle))
                let (passage, matched) = range.map { passage(in: pageText, around: $0) }
                    ?? (String(pageText.prefix(passageRadius * 2)), nil)
                hits.append(ReadingHit(
                    home: .pdf(url: url, page: number),
                    title: title,
                    author: author,
                    section: found.count > 1 ? "\(found.count) mentions" : nil,
                    passage: passage,
                    matchRange: matched,
                    isExact: true))
            }
        }
        return (hits.sorted { $0.title < $1.title }, read)
    }

    // MARK: Words

    /// The comparison form: case folded, accents dropped, curly quotes
    /// and dashes made straight, every run of whitespace one space.
    /// Text lifted out of a PDF arrives full of line breaks and typographic
    /// quotes, and a phrase that "obviously matches" would not without this.
    nonisolated static func normalised(_ text: String) -> String {
        var out = text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                               locale: .current)
        for (curly, straight) in [("\u{2018}", "'"), ("\u{2019}", "'"),
                                  ("\u{201C}", "\""), ("\u{201D}", "\""),
                                  ("\u{2013}", "-"), ("\u{2014}", "-"),
                                  ("\u{00AD}", "")] {
            out = out.replacingOccurrences(of: curly, with: straight)
        }
        out = out.replacingOccurrences(of: "\\s+", with: " ",
                                       options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func tidyForDisplay(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The words around the match, cut at word boundaries with ellipses
    /// where the text was cut.
    nonisolated private static func passage(in text: String, around range: Range<String.Index>)
        -> (String, Range<String.Index>?) {
        let start = text.index(range.lowerBound,
                               offsetBy: -passageRadius,
                               limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound,
                             offsetBy: passageRadius,
                             limitedBy: text.endIndex) ?? text.endIndex
        var slice = String(text[start..<end])
        var offset = text.distance(from: start, to: range.lowerBound)
        if start != text.startIndex {
            slice = "…" + slice
            offset += 1
        }
        if end != text.endIndex { slice += "…" }
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        guard let lower = slice.index(slice.startIndex, offsetBy: offset,
                                      limitedBy: slice.endIndex),
              let upper = slice.index(lower, offsetBy: length,
                                      limitedBy: slice.endIndex)
        else { return (slice, nil) }
        return (slice, lower..<upper)
    }
}

// MARK: - The panel

/// The answer: every place the phrase was read, the library's first and
/// Reader's PDFs after. A row opens what it names — the reading at its
/// paragraph, or the PDF at the page it says.
struct ReadingSearchView: View {
    @Environment(AppModel.self) private var model
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var search: ReadingSearch { model.readingSearch }

    var body: some View {
        VStack(spacing: 0) {
            askBar
            Divider()
            if search.isSearching && search.hits.isEmpty {
                ProgressView("Looking through your reading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.hits.isEmpty {
                ContentUnavailableView {
                    Label(search.phrase.isEmpty ? "Where Have I Read This?" : "Not Found",
                          systemImage: "text.magnifyingglass")
                } description: {
                    Text(search.phrase.isEmpty
                         ? "Paste or type a phrase — or select one in any app and choose Where Have I Read This? from the Services menu."
                         : "Nothing in your reading carries those words. \(search.scopeNote)")
                }
            } else {
                List(search.hits) { hit in
                    ReadingHitRow(hit: hit) { open(hit) }
                }
                .listStyle(.inset)
            }
            if !search.hits.isEmpty || search.isSearching {
                footer
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            typed = search.phrase
            fieldFocused = search.phrase.isEmpty
        }
        .onChange(of: search.phrase) { typed = search.phrase }
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("A phrase you remember reading", text: $typed)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { search.run(typed, in: model) }
            if !typed.isEmpty {
                Button {
                    typed = ""
                    search.clear()
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button("Find") { search.run(typed, in: model) }
                .disabled(typed.trimmingCharacters(in: .whitespaces).count < 3)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if search.isSearching {
                ProgressView().controlSize(.small)
                Text("Reading the PDFs…")
            } else {
                Text("\(search.hits.count) place\(search.hits.count == 1 ? "" : "s") · \(search.scopeNote)")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func open(_ hit: ReadingHit) {
        switch hit.home {
        case .library(let docID, let paragraphID):
            guard let doc = model.index.byID[docID]?.doc else {
                NSSound.beep()
                return
            }
            model.open(doc, fragment: paragraphID)
        case .pdf(let url, _):
            // Reader itself when it is installed, as a cited PDF opens
            // (AppModel.openPDFInReader). The page is named in the row,
            // because a file URL cannot carry one across apps.
            model.openPDFInReader(url)
        }
    }
}

private struct ReadingHitRow: View {
    let hit: ReadingHit
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: hit.isPDF ? "doc.richtext" : "doc.text")
                        .foregroundStyle(.secondary)
                    Text(hit.title)
                        .font(.headline)
                        .lineLimit(1)
                    if !hit.isExact {
                        Text("the same words, scattered")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if !hit.author.isEmpty || !hit.placeDescription.isEmpty {
                    Text([hit.author, hit.placeDescription]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(painted)
                    .font(.callout)
                    .lineLimit(3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The phrase itself, lit inside the words around it.
    private var painted: AttributedString {
        var out = AttributedString(hit.passage)
        guard let range = hit.matchRange,
              let lower = AttributedString.Index(range.lowerBound, within: out),
              let upper = AttributedString.Index(range.upperBound, within: out)
        else { return out }
        out[lower..<upper].backgroundColor = .yellow.opacity(0.35)
        out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        return out
    }
}
#endif
