#if os(macOS)
import SwiftUI

/// One place in the library that cites or quotes a passage: the citing
/// document, the paragraph that does it, and its words.
struct CitedHere: Identifiable, Hashable {
    let citingDocID: String
    let citingTitle: String
    let citingParagraphID: String
    let snippet: String
    /// The link's kind when it names one (cites, transcludes, supports…).
    let rel: String?
    var id: String { citingDocID + "#" + citingParagraphID }
}

/// A relationship a book declares to another work: the semantic record's
/// `links` (§9.6), the typed links in its text (supports, extends,
/// retracts…), and the editions it replaces or is replaced by (§4.3).
struct DeclaredRelationship: Identifiable, Hashable {
    let rel: String
    /// The other work's identity as the book names it.
    let target: String
    /// The passage within it, when the link names one.
    let targetAddress: String?
    /// The passage of this book that makes the link, when known.
    let fromAddress: String?
    let quotedText: String?
    var id: String { [rel, target, targetAddress ?? "", fromAddress ?? ""].joined(separator: "|") }
}

extension AppModel {

    /// The library book a work's identity names: its shelf address,
    /// package identifier (`dc:identifier`) or DOI.
    func libraryRecord(forIdentity identity: String) -> EPUBRecord? {
        let wanted = identity.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        if let record = epubRecord(forAddress: wanted) { return record }
        let lowered = wanted.lowercased()
        let doi = lowered.replacingOccurrences(of: "https://doi.org/", with: "")
            .replacingOccurrences(of: "doi:", with: "")
        return epubRecords.first { $0.packageIdentifier?.lowercased() == lowered }
            ?? epubRecords.first { $0.doi?.lowercased() == doi }
    }

    /// Every passage of this book the library cites or quotes, by the
    /// passage's bare id: which document does it, in which paragraph.
    /// Read from the citing documents' own words — an `origamitext://`
    /// link (or its web carrier) or an `[address#paragraph]` citation —
    /// so the citing paragraph is known and opens directly. Scanned once
    /// per book and library revision.
    func citedHere(inBook record: EPUBRecord) -> [String: [CitedHere]] {
        _ = citedHereStamp
        let key = "\(record.folder)|\(index.revision)"
        if let cache = citedHereCache, cache.key == key { return cache.map }
        // Scanned off the main thread; until it lands, the last scan for
        // this book stands (or nothing, the first time).
        if citedHerePending != key {
            citedHerePending = key
            let identities = Set([record.id, record.packageIdentifier, record.doi, record.folder]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty })
            let docs = index.allByID.values.map(\.doc)
            Task.detached(priority: .utility) {
                let map = AppModel.citedHere(in: docs, identities: identities)
                await MainActor.run {
                    self.citedHereCache = (key, map)
                    if self.citedHerePending == key { self.citedHerePending = nil }
                    self.citedHereStamp += 1
                }
            }
        }
        if let cache = citedHereCache, cache.key.hasPrefix(record.folder + "|") { return cache.map }
        return [:]
    }

    /// The scan itself, over any set of documents: every paragraph that
    /// links into a passage of the work the identities name.
    nonisolated static func citedHere(in docs: [LiquidDoc],
                                      identities: Set<String>) -> [String: [CitedHere]] {
        func bare(_ fragment: String) -> String {
            fragment.split(separator: "#", omittingEmptySubsequences: false).last.map(String.init) ?? fragment
        }
        var map: [String: [CitedHere]] = [:]
        let urlPattern = try? NSRegularExpression(
            pattern: #"\]\(((?:origamitext://open/|https://origamitext\.app/o/)[^)\s]+)\)"#)
        let tokenPattern = try? NSRegularExpression(
            pattern: #"\[([^\[\]\s#]+)#([^\[\]\s]+)\]"#)
        for doc in docs {
            guard !identities.contains(doc.id.lowercased()) else { continue }
            for paragraph in doc.body ?? [] {
                let text = paragraph.text
                guard text.contains("#") else { continue }
                let range = NSRange(text.startIndex..., in: text)
                var hits: [(address: String, fragment: String, rel: String?)] = []
                for match in urlPattern?.matches(in: text, range: range) ?? [] {
                    guard let r = Range(match.range(at: 1), in: text) else { continue }
                    var link = String(text[r])
                    if link.hasPrefix(OrigamiCitation.webCarrierPrefix) {
                        link = "origamitext://open/" + link.dropFirst(OrigamiCitation.webCarrierPrefix.count)
                    }
                    let parsed = EPUBReaderView.Coordinator.parseOrigamiURL(link)
                    if let fragment = parsed.fragment, !parsed.address.isEmpty {
                        hits.append((parsed.address, fragment, nil))
                    }
                }
                for match in tokenPattern?.matches(in: text, range: range) ?? [] {
                    guard let target = Range(match.range(at: 1), in: text),
                          let fragment = Range(match.range(at: 2), in: text) else { continue }
                    // "[supports:address#p]" carries its relation first; a
                    // prefix that is no relation ("urn:uuid:…") is part of
                    // the address.
                    var address = String(text[target])
                    var rel: String?
                    if let colon = address.firstIndex(of: ":"),
                       DocumentRelation(rawValue: String(address[..<colon])) != nil {
                        rel = String(address[..<colon])
                        address = String(address[address.index(after: colon)...])
                    }
                    hits.append((address, String(text[fragment]), rel))
                }
                for hit in hits where identities.contains(hit.address.lowercased()) {
                    let words = Self.readableWords(paragraph.text)
                    let snippet = words.count > 220 ? String(words.prefix(220)) + "\u{2026}" : words
                    let cited = CitedHere(citingDocID: doc.id, citingTitle: doc.title,
                                          citingParagraphID: paragraph.id, snippet: snippet,
                                          rel: hit.rel)
                    let target = bare(hit.fragment)
                    if !(map[target]?.contains(cited) ?? false) {
                        map[target, default: []].append(cited)
                    }
                }
            }
        }
        return map
    }

    /// A paragraph's words as a reader sees them: link text kept, the
    /// format's tokens (citations, notes, addresses) and emphasis marks
    /// dropped.
    nonisolated static func readableWords(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                                            options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[(?:cite|note|inote):[^\]]*\]"#, with: "",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[[^\[\]\s]+#[^\[\]\s]+\]"#, with: "",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Opens the citing passage: a library book at its paragraph, or a
    /// community-folder document the same way.
    func openCitedHere(_ cited: CitedHere) {
        if epubRecord(forAddress: cited.citingDocID) != nil {
            openEPUB(address: cited.citingDocID, fragment: cited.citingParagraphID)
        } else {
            follow(to: cited.citingDocID, fragment: cited.citingParagraphID, rel: nil)
        }
    }

    /// What the book declares about its relations to other works.
    func declaredRelationships(for record: EPUBRecord, doc: LiquidDoc?) -> [DeclaredRelationship] {
        var out: [DeclaredRelationship] = []
        let base = unpackedFolder(for: record)
        let links = OrigamiEPUBImporter.recordData(
                inUnpackedFolder: base, properties: "origami:visual-meta",
                fileName: "visual-meta.json")
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .flatMap { $0["links"] as? [[String: Any]] } ?? []
        for link in links {
            guard let edition = link["toEdition"] as? String, !edition.isEmpty else { continue }
            out.append(DeclaredRelationship(
                rel: (link["rel"] as? String) ?? "cites", target: edition,
                targetAddress: link["toAddress"] as? String,
                fromAddress: link["fromAddress"] as? String,
                quotedText: link["quotedText"] as? String))
        }
        // Typed links in the text: the discourse relations a writer set
        // (supports, extends, retracts…). Plain citations are the
        // References list's business.
        for link in doc?.links ?? [] {
            guard let rel = link.rel, rel != "cites", !link.to.isEmpty else { continue }
            out.append(DeclaredRelationship(rel: rel, target: link.to, targetAddress: link.fragment,
                                            fromAddress: nil, quotedText: link.span))
        }
        if let info = editionInfo(for: record) {
            out += info.replaces.map {
                DeclaredRelationship(rel: "replaces", target: $0, targetAddress: nil,
                                     fromAddress: nil, quotedText: nil)
            }
            out += info.isReplacedBy.map {
                DeclaredRelationship(rel: "is replaced by", target: $0, targetAddress: nil,
                                     fromAddress: nil, quotedText: nil)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }
}

/// The list the margin marker opens: each citing passage, its document
/// and words; a click opens it there.
struct CitedHereList: View {
    @Environment(AppModel.self) private var model
    let citations: [CitedHere]
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(citations.count == 1 ? "Cited in 1 place in your library"
                                      : "Cited in \(citations.count) places in your library")
                .font(.headline)
                .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(citations) { cited in
                        Button {
                            onOpen()
                            model.openCitedHere(cited)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(cited.citingTitle).font(.callout.bold()).lineLimit(2)
                                    if let rel = cited.rel, rel != "cites" {
                                        Text(rel).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(cited.snippet)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this passage")
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 420)
    }
}

/// The margin mark on a cited paragraph: a quote sign and how many
/// places cite it, opening the list.
struct CitedHereMarker: View {
    let citations: [CitedHere]
    @State private var showsList = false

    var body: some View {
        Button { showsList = true } label: {
            Label("\(citations.count)", systemImage: "quote.bubble")
                .font(.caption)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Cited in your library")
        .popover(isPresented: $showsList, arrowEdge: .trailing) {
            CitedHereList(citations: citations) { showsList = false }
        }
    }
}
#endif
