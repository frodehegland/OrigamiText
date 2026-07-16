import Foundation

/// A paragraph ranked by how many documents cite it directly.
nonisolated struct HotParagraph: Identifiable, Sendable {
    let doc: LiquidDoc
    let paragraph: LiquidDoc.Paragraph
    let citations: [BacklinkRef]
    var id: String { "\(doc.id)#\(paragraph.id)" }
}

nonisolated struct AuthorLinkCount: Identifiable, Sendable {
    let name: String
    let count: Int
    var id: String { name }
}

/// One author's presence in the library: their documents plus who they cite
/// and who cites them (derived from resolved links; revisions excluded).
nonisolated struct AuthorSummary: Identifiable, Sendable {
    let name: String
    let entries: [IndexEntry]          // sorted by created ascending
    let cites: [AuthorLinkCount]       // outgoing, by target author
    let citedBy: [AuthorLinkCount]     // incoming, by source author
    var id: String { name }

    var activeRangeText: String {
        guard let first = entries.first?.doc.created, let last = entries.last?.doc.created else { return "" }
        let style = Date.FormatStyle.dateTime.year().month(.abbreviated)
        let from = first.formatted(style)
        let to = last.formatted(style)
        return from == to ? from : "\(from) – \(to)"
    }
}

/// How much changed between a document and the version it supersedes:
/// content paragraphs edited, added, removed, and unchanged, plus the net
/// word difference. Visual-Meta appendices are excluded — they differ
/// between any two publications and are metadata, not content. Paragraphs
/// are matched by text (ids regenerate between versions): exact matches
/// count unchanged, then leftovers pair by word overlap as edits.
nonisolated struct RevisionDelta: Sendable {
    let edited: Int
    let added: Int
    let removed: Int
    let unchanged: Int
    let wordDelta: Int

    var isIdentical: Bool { edited == 0 && added == 0 && removed == 0 }

    /// Share of the document that changed: edited, added, and removed
    /// paragraphs over every paragraph the two versions span.
    var percentChanged: Int {
        let total = edited + added + removed + unchanged
        guard total > 0 else { return 0 }
        return Int((Double(edited + added + removed) / Double(total) * 100).rounded())
    }

    var summary: String {
        if isIdentical { return "No content changes — the text is identical." }
        var parts: [String] = []
        if edited > 0 { parts.append("\(edited) \(edited == 1 ? "paragraph" : "paragraphs") edited") }
        if added > 0 { parts.append("\(added) added") }
        if removed > 0 { parts.append("\(removed) removed") }
        var text = parts.joined(separator: ", ") + " · \(unchanged) unchanged"
        if wordDelta != 0 {
            let count = abs(wordDelta)
            text += " · \(count) \(count == 1 ? "word" : "words") \(wordDelta > 0 ? "longer" : "shorter")"
        }
        return text
    }

    static func between(old: LiquidDoc, new: LiquidDoc) -> RevisionDelta {
        let oldTexts = contentTexts(of: old)
        let newTexts = contentTexts(of: new)

        // Exact matches are unchanged paragraphs.
        var newMatched = [Bool](repeating: false, count: newTexts.count)
        var oldLeftovers: [Set<String>] = []
        var unchanged = 0
        for text in oldTexts {
            if let match = newTexts.indices.first(where: { !newMatched[$0] && newTexts[$0] == text }) {
                newMatched[match] = true
                unchanged += 1
            } else {
                oldLeftovers.append(words(of: text))
            }
        }
        var newLeftovers = newTexts.indices.filter { !newMatched[$0] }.map { words(of: newTexts[$0]) }

        // A leftover pair sharing enough vocabulary is one edited
        // paragraph; whatever finds no counterpart was added or removed.
        var edited = 0
        var removed = 0
        for oldWords in oldLeftovers {
            let best = newLeftovers.indices
                .map { ($0, similarity(oldWords, newLeftovers[$0])) }
                .max { $0.1 < $1.1 }
            if let best, best.1 >= 0.4 {
                newLeftovers.remove(at: best.0)
                edited += 1
            } else {
                removed += 1
            }
        }

        return RevisionDelta(edited: edited,
                             added: newLeftovers.count,
                             removed: removed,
                             unchanged: unchanged,
                             wordDelta: wordCount(of: newTexts) - wordCount(of: oldTexts))
    }

    private static func contentTexts(of doc: LiquidDoc) -> [String] {
        guard let body = doc.body else { return [] }
        let metaIDs = doc.visualMetaParagraphIDs
        return body.filter { !metaIDs.contains($0.id) }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func words(of text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Jaccard similarity of two word sets.
    private static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    private static func wordCount(of texts: [String]) -> Int {
        texts.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
    }
}

/// One statement a person made in a meeting transcript, anywhere in the
/// library.
nonisolated struct SpokenStatement: Identifiable, Sendable {
    let doc: LiquidDoc
    let paragraph: LiquidDoc.Paragraph
    var id: String { "\(doc.id)#\(paragraph.id)" }
}

/// Library housekeeping: everything that needs attention in one place.
nonisolated struct HealthReport: Sendable {
    struct UnresolvedLink: Identifiable, Sendable {
        let sourceDoc: LiquidDoc
        let to: String
        let rel: String?
        let ordinal: Int
        var id: String { "\(sourceDoc.id)-\(ordinal)" }
    }

    var documentCount = 0
    var supersededCount = 0
    var unresolvedLinks: [UnresolvedLink] = []
    var unlinked: [IndexEntry] = []
    var duplicates: [IndexEntry] = []
    var missingSidecarFiles: [IndexEntry] = []
    var unreadableFiles: [UnreadableFile] = []

    var issueCount: Int {
        unresolvedLinks.count + duplicates.count + missingSidecarFiles.count + unreadableFiles.count
    }
}

/// Pure derivations over the index's maps. Each library view computes its
/// data here so views stay thin and new views can reuse the same building
/// blocks.
nonisolated enum LibraryInsights {

    static func hotParagraphs(byID: [String: IndexEntry], backlinks: [String: [BacklinkRef]]) -> [HotParagraph] {
        var result: [HotParagraph] = []
        for (targetID, refs) in backlinks {
            guard let entry = byID[targetID], let body = entry.doc.body else { continue }
            let byFragment = Dictionary(grouping: refs.filter { $0.fragment != nil }, by: { $0.fragment ?? "" })
            for (fragment, fragmentRefs) in byFragment {
                guard let paragraph = body.first(where: { $0.id == fragment }) else { continue }
                result.append(HotParagraph(doc: entry.doc, paragraph: paragraph, citations: fragmentRefs))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.citations.count != rhs.citations.count { return lhs.citations.count > rhs.citations.count }
            return lhs.doc.listedDate < rhs.doc.listedDate
        }
    }

    /// Everything a person has said across meeting transcripts: the
    /// paragraphs anywhere in the library carrying their name as
    /// `speaker`. Names match softly (case-insensitive), like authors.
    static func statements(by name: String, byID: [String: IndexEntry]) -> [SpokenStatement] {
        let target = name.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return [] }
        var result: [SpokenStatement] = []
        for entry in byID.values {
            guard let body = entry.doc.body else { continue }
            for paragraph in body
            where paragraph.speaker?.caseInsensitiveCompare(target) == .orderedSame {
                result.append(SpokenStatement(doc: entry.doc, paragraph: paragraph))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.doc.listedDate != rhs.doc.listedDate { return lhs.doc.listedDate > rhs.doc.listedDate }
            if lhs.doc.id != rhs.doc.id { return lhs.doc.id < rhs.doc.id }
            return lhs.paragraph.id.localizedStandardCompare(rhs.paragraph.id) == .orderedAscending
        }
    }

    static func authors(byID: [String: IndexEntry]) -> [AuthorSummary] {
        func normalized(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Unknown" : trimmed
        }

        var docsByAuthor: [String: [IndexEntry]] = [:]
        for entry in byID.values {
            docsByAuthor[normalized(entry.doc.author), default: []].append(entry)
        }

        // from-author -> to-author -> count; revisions of one's own work
        // are versioning, not citation.
        var citations: [String: [String: Int]] = [:]
        for entry in byID.values {
            let from = normalized(entry.doc.author)
            for link in entry.doc.links where link.rel != "revises" {
                guard let target = byID[link.to] else { continue }
                citations[from, default: [:]][normalized(target.doc.author), default: 0] += 1
            }
        }

        return docsByAuthor
            .map { name, entries in
                let cites = (citations[name] ?? [:])
                    .map { AuthorLinkCount(name: $0.key, count: $0.value) }
                    .sorted { $0.count > $1.count }
                let citedBy = citations
                    .compactMap { from, targets in
                        targets[name].map { AuthorLinkCount(name: from, count: $0) }
                    }
                    .sorted { $0.count > $1.count }
                return AuthorSummary(name: name,
                                     entries: entries.sorted { $0.doc.listedDate < $1.doc.listedDate },
                                     cites: cites,
                                     citedBy: citedBy)
            }
            .sorted { lhs, rhs in
                if lhs.entries.count != rhs.entries.count { return lhs.entries.count > rhs.entries.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func healthReport(byID: [String: IndexEntry],
                             backlinks: [String: [BacklinkRef]],
                             unreadable: [UnreadableFile],
                             superseded: Set<String>) -> HealthReport {
        var report = HealthReport()
        report.documentCount = byID.count
        report.supersededCount = superseded.count
        report.unreadableFiles = unreadable

        var ordinal = 0
        let entries = byID.values.sorted { $0.doc.listedDate < $1.doc.listedDate }
        for entry in entries {
            for link in entry.doc.links where byID[link.to] == nil {
                ordinal += 1
                report.unresolvedLinks.append(HealthReport.UnresolvedLink(
                    sourceDoc: entry.doc, to: link.to, rel: link.rel, ordinal: ordinal))
            }
            if entry.doc.links.isEmpty, (backlinks[entry.id] ?? []).isEmpty {
                report.unlinked.append(entry)
            }
            if entry.hasDuplicate {
                report.duplicates.append(entry)
            }
            if let wraps = entry.doc.wraps {
                let fileURL = URL(fileURLWithPath: wraps.file,
                                  relativeTo: entry.doc.fileURL.deletingLastPathComponent())
                    .standardizedFileURL
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    report.missingSidecarFiles.append(entry)
                }
            }
        }
        return report
    }
}
