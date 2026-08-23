import SwiftUI

/// The reader's names and colours for the annotation kinds, editable in
/// Settings ▸ Annotation. The stored annotation always carries the
/// canonical kind; names and colours are how this reader sees them.
enum AnnotationKindStyle {

    private static let namesKey = "annotationKindNames"
    private static let colorsKey = "annotationKindColors"

    static func displayName(of kind: ReaderAnnotationKind) -> String {
        let names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String]
        let custom = names?[kind.rawValue]?.trimmingCharacters(in: .whitespaces)
        return custom?.isEmpty == false ? custom! : kind.rawValue
    }

    static func setDisplayName(_ name: String, for kind: ReaderAnnotationKind) {
        var names = (UserDefaults.standard.dictionary(forKey: namesKey)
            as? [String: String]) ?? [:]
        names[kind.rawValue] = name
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    static func defaultHex(for kind: ReaderAnnotationKind) -> String {
        switch kind {
        case .important: "E4572E"
        case .quotable: "2E8B8B"
        case .great: "3A9B35"
        case .disagree: "C93C3C"
        case .languageIssue: "8E5BC0"
        case .problematic: "D98E1B"
        case .whatIsThis: "3B6FD4"
        case .highlight: "E8C51D"
        case .strikethrough: "8A8A8A"
        }
    }

    static func hex(of kind: ReaderAnnotationKind) -> String {
        let colors = UserDefaults.standard.dictionary(forKey: colorsKey) as? [String: String]
        return colors?[kind.rawValue] ?? defaultHex(for: kind)
    }

    static func setHex(_ hex: String, for kind: ReaderAnnotationKind) {
        var colors = (UserDefaults.standard.dictionary(forKey: colorsKey)
            as? [String: String]) ?? [:]
        colors[kind.rawValue] = hex
        UserDefaults.standard.set(colors, forKey: colorsKey)
    }

    static func color(of kind: ReaderAnnotationKind) -> Color {
        Color(annotationHex: hex(of: kind))
    }

    static func reset(_ kind: ReaderAnnotationKind) {
        var names = (UserDefaults.standard.dictionary(forKey: namesKey)
            as? [String: String]) ?? [:]
        names.removeValue(forKey: kind.rawValue)
        UserDefaults.standard.set(names, forKey: namesKey)
        var colors = (UserDefaults.standard.dictionary(forKey: colorsKey)
            as? [String: String]) ?? [:]
        colors.removeValue(forKey: kind.rawValue)
        UserDefaults.standard.set(colors, forKey: colorsKey)
    }
}

extension Color {
    /// "E4572E" → the colour; anything unreadable → yellow.
    init(annotationHex hex: String) {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 6 else {
            self = .yellow
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// The colour as "RRGGBB", for the kind store.
    var annotationHex: String {
        let converted = NSColor(self).usingColorSpace(.sRGB) ?? .yellow
        return String(format: "%02X%02X%02X",
                      Int(round(converted.redComponent * 255)),
                      Int(round(converted.greenComponent * 255)),
                      Int(round(converted.blueComponent * 255)))
    }
}

/// Views ▸ Annotations: every annotation across every book — the
/// reader's own layer over the library. Each is a W3C Web Annotation
/// (the Hypothesis model), held in a JSON-LD sidecar beside the
/// unpacked books, never inside them: the book is the author's, the
/// annotations are the reader's.
///
/// Grouped by book, the most recently annotated book first. Find (at
/// the foot of the list) searches across every document at once — the
/// quoted words, the notes, and the books' titles. Click an annotation
/// to open its book at the very words, by the same anchoring ladder
/// the reader paints highlights with.
struct AnnotationsListView: View {
    @Environment(AppModel.self) private var model

    private struct BookGroup: Identifiable {
        let address: String
        let title: String
        let items: [AppModel.LibraryAnnotation]
        var id: String { address }
    }

    /// The annotations Find leaves standing, grouped by book — the
    /// group order follows each book's newest annotation.
    private var groups: [BookGroup] {
        let query = model.searchText.trimmingCharacters(in: .whitespaces)
        let shown = model.allAnnotations.filter { item in
            guard !query.isEmpty else { return true }
            let haystack = [item.exact,
                            item.annotation.body?.value,
                            item.annotation.creator?.name,
                            bookTitle(for: item.address)]
                .compactMap { $0 }
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
        var order: [String] = []
        var byAddress: [String: [AppModel.LibraryAnnotation]] = [:]
        for item in shown {   // groups by most recently annotated book
            if byAddress[item.address] == nil { order.append(item.address) }
            byAddress[item.address, default: []].append(item)
        }
        return order.map { address in
            // Within a book, annotations read in document order — the
            // ProgressionSelector — notes without one at the end, by
            // when they were written.
            let items = (byAddress[address] ?? []).sorted {
                let a = $0.progression ?? 2
                let b = $1.progression ?? 2
                if a != b { return a < b }
                return $0.annotation.created < $1.annotation.created
            }
            return BookGroup(address: address,
                             title: bookTitle(for: address),
                             items: items)
        }
    }

    /// The open book's unanchored annotations — the document changed
    /// beyond re-anchoring. Marked, never lost.
    private var orphanIDs: Set<String> {
        guard let book = model.openEPUB,
              let doc = model.readingDoc(forBook: book) else { return [] }
        return model.orphanedAnnotationIDs(for: doc)
    }

    private func bookTitle(for address: String) -> String {
        model.epubRecord(forAddress: address)?.title ?? address
    }

    var body: some View {
        let orphans = orphanIDs
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(for: item, isOrphan: orphans.contains(item.id))
                    }
                } header: {
                    Text(group.title)
                        .contextMenu {
                            Button("Export Annotations…") {
                                exportAnnotations(for: group)
                            }
                        }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView {
                        Label("No Annotations Yet", systemImage: "highlighter")
                    } description: {
                        Text("Select words in a book and highlight or comment — your annotations live beside the books, never inside them, and gather here across the whole library.")
                    }
                } else {
                    ContentUnavailableView(
                        "No Matching Annotations",
                        systemImage: "magnifyingglass")
                }
            }
        }
    }

    private func row(for item: AppModel.LibraryAnnotation,
                     isOrphan: Bool = false) -> some View {
        Button {
            model.openAnnotation(item)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: item.annotation))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    if let exact = item.exact {
                        Text("“\(exact)”")
                            .italic()
                            .lineLimit(3)
                    }
                    if let note = item.annotation.body?.value, !note.isEmpty {
                        Text(note)
                            .lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        Text(item.annotation.created.formatted(date: .abbreviated,
                                                               time: .shortened))
                        if isOrphan {
                            // The document changed beyond re-anchoring;
                            // the annotation waits here, never lost.
                            Text("· unanchored")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy as Citation") {
                copyCitation(for: item)
            }
            Divider()
            Button("Remove Annotation", role: .destructive) {
                model.removeAnnotation(id: item.annotation.id, address: item.address)
            }
        }
    }

    /// One pure BibTeX entry for the annotation: the book's metadata,
    /// the quoted words in `quote`, the reader's note in `annotation`,
    /// and the vm-id address that reopens the book at the very place.
    private func copyCitation(for item: AppModel.LibraryAnnotation) {
        let record = model.epubRecord(forAddress: item.address)
        let bibtex = OrigamiReading.bibTeXEntry(
            title: record?.title ?? bookTitle(for: item.address),
            author: record?.author ?? item.annotation.creator?.name ?? "",
            year: record?.dateISO.map { String($0.prefix(4)) },
            publication: record?.publication,
            quote: item.exact,
            annotation: item.annotation.body?.value,
            address: item.address + (item.fragment.map { "#\($0)" } ?? ""))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(bibtex, forType: .string)
        model.showNote("Citation copied as BibTeX")
    }

    /// Saves one book's annotations as a standalone W3C
    /// AnnotationCollection — the heart of a Readium annotation set
    /// (`.annotation`), readable by standards-following readers.
    private func exportAnnotations(for group: BookGroup) {
        guard let data = AnnotationStore.exportData(for: group.address,
                                                    in: AppModel.annotationsRoot)
        else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = group.title + ".annotation"
        panel.canCreateDirectories = true
        panel.message = "Export this book's annotations as a W3C annotation collection."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
        model.showNote("Exported the annotations of “\(group.title)”")
    }

    private func icon(for motivation: String) -> String {
        switch motivation {
        case WebAnnotation.Motivation.commenting: "text.bubble"
        case WebAnnotation.Motivation.tagging: "tag"
        case WebAnnotation.Motivation.describing: "doc.text"
        default: "highlighter"
        }
    }

    /// The kind's own symbol where the annotation carries one of the
    /// reader's judgments; the motivation's otherwise.
    private func icon(for annotation: WebAnnotation) -> String {
        ReaderAnnotationKind.kind(of: annotation)?.systemImage
            ?? icon(for: annotation.motivation)
    }
}
