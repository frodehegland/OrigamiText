#if os(macOS)
import Foundation
import NaturalLanguage
import Observation

/// Find Stances (Stance Relations Build Brief, 2 Nov 2026): for every
/// pair of pieces in a corpus where one cites the other, the model reads
/// the passage where the source actually discusses the target — the
/// citing sentence and its neighbours — beside the target's own most
/// relevant passages, and names at most two stances (agrees with,
/// contradicts, extends, responds to) or none. Every stance must quote
/// both texts verbatim; the quotes are checked by exact match before
/// anything is kept. Every stance is born `proposed`; the reader confirms
/// or severs it on the headset, at the end of its line. A document's own
/// "responds-to" link is taken as a confirmed Responds to, no model asked.
///
/// Run by Library Upkeep after a corpus is built, at background priority
/// and paced to the reader. One pair is read once per prompt version.
@MainActor @Observable
final class StanceFinder {
    static let shared = StanceFinder()

    private(set) var isRunning = false
    private(set) var log: [String] = []

    /// Review decisions are only comparable within one version of the
    /// prompt; a new version reads every pair again.
    static let promptVersion = "stance-1"

    /// The brief's system message, as written.
    static let systemPrompt = """
        You classify how a SOURCE article relates to a TARGET article it cites, using only the text given. Return JSON only.

        Stances (directed from SOURCE to TARGET):
        - agrees_with: SOURCE states a specific finding, argument or position of TARGET as true, confirms it with its own results, or explicitly endorses it.
        - contradicts: SOURCE reports a result, argument or position that conflicts with a specific claim of TARGET, or explicitly disputes it.
        - extends: SOURCE takes TARGET's method, model, dataset, formalism or argument as its starting point and adds to, generalises, adapts or improves it. Plain reuse without change is NOT extends.
        - responds_to: SOURCE is written as a reply, commentary, rebuttal, follow-up or answer to TARGET as a whole.
        - none: SOURCE only mentions, uses, or describes TARGET as background. This is the expected answer for most passages.

        Rules:
        1. Default to none. A stance needs an explicit signal in the passage. Topic overlap is not a signal.
        2. Return at most two stances. Each needs its own quotes.
        3. source_quote must be copied verbatim from SOURCE_WINDOW, 25 to 400 characters, no edits, no ellipses.
        4. target_quote must be copied verbatim from one of the TARGET_PASSAGES; required for agrees_with and contradicts, optional for extends and responds_to. Give the passage id it came from.
        5. rationale: one sentence saying which words in the quotes carry the stance.
        6. confidence: 0 to 1. Use 0.9 or above only when the passage names the stance in so many words. If unsure between contradicts and none, choose none. If unsure between agrees_with and extends, choose extends.
        7. Never invent text. If you cannot find a quote that supports a stance, return none.

        Reply as: {"stances": [{"stance": "...", "source_quote": "...", "source_element": "...", "target_quote": "...", "target_passage_id": "...", "rationale": "...", "confidence": 0.0}]}. An empty list means none.
        """

    static let stanceTypes: Set<String> = ["agrees_with", "contradicts", "extends", "responds_to"]

    // MARK: Which pairs

    /// One citing pair: source piece cites target piece.
    struct Pair: Hashable {
        let source: String
        let target: String
        var checkKey: String { source + "→" + target + "|" + StanceFinder.promptVersion }
    }

    /// The citing pairs inside a corpus not yet read with this prompt.
    static func pendingPairs(in corpus: CorpusRelations.Corpus) -> [Pair] {
        let checked = Set(corpus.stancesChecked ?? [])
        var pairs: [Pair] = []
        var seen = Set<Pair>()
        for citation in corpus.citations where !citation.from.hasPrefix(CorpusRelations.volumePrefix) {
            guard let target = corpus.works[citation.to]?.inCorpus,
                  target.hasPrefix(CorpusRelations.piecePrefix) else { continue }
            let pair = Pair(source: citation.from, target: String(target.dropFirst(CorpusRelations.piecePrefix.count)))
            guard pair.source != pair.target, corpus.pieces[pair.target] != nil,
                  !checked.contains(pair.checkKey), seen.insert(pair).inserted else { continue }
            pairs.append(pair)
        }
        return pairs
    }

    // MARK: The pass

    func run(corpusID: String, model: AppModel, background: Bool) {
        guard !isRunning, let corpus = CorpusRelationsBuilder.shared.file?.corpora[corpusID] else { return }
        let pairs = Self.pendingPairs(in: corpus)
        guard !pairs.isEmpty else { return }
        isRunning = true
        log = ["Finding stances in \(corpus.name): \(pairs.count) citing pair\(pairs.count == 1 ? "" : "s") to read."]
        Task(priority: background ? .background : nil) {
            defer { isRunning = false }
            Self.foldReviews(model: model)
            var proposed = 0, dropped = 0, windows = 0
            for (index, pair) in pairs.enumerated() {
                if Task.isCancelled { break }
                if background { await BackgroundPace.waitForQuiet() }
                let result = await read(pair, in: corpus, model: model)
                windows += result.windows
                dropped += result.dropped
                proposed += result.stances.count
                CorpusRelationsBuilder.shared.update(corpus: corpusID, model: model) { corpus in
                    var stances = corpus.stances ?? []
                    for stance in result.stances { Self.merge(stance, into: &stances) }
                    corpus.stances = stances
                    corpus.stancesChecked = (corpus.stancesChecked ?? []) + [pair.checkKey]
                }
                if index % 10 == 9 { log.append("   \(index + 1) of \(pairs.count) pairs read.") }
            }
            log.append("Done: \(windows) passages read, \(proposed) stances proposed, \(dropped) dropped for quotes not found in the text.")
        }
    }

    /// A stance kept once per (source, target, stance): a reader's decision
    /// is never undone by a re-run; a stronger proposal replaces a weaker
    /// one, and further evidence is kept beside it (three passages at most).
    static func merge(_ stance: CorpusRelations.Stance, into stances: inout [CorpusRelations.Stance]) {
        guard let index = stances.firstIndex(where: { $0.id == stance.id }) else {
            stances.append(stance)
            return
        }
        var held = stances[index]
        let more = (stance.evidence ?? []).filter { new in !(held.evidence ?? []).contains(new) }
        if held.review == "confirmed" || held.review == "rejected" {
            held.evidence = Array(((held.evidence ?? []) + more).prefix(6))
        } else if (stance.confidence ?? 0) > (held.confidence ?? 0) {
            var replaced = stance
            replaced.evidence = Array(((stance.evidence ?? []) + (held.evidence ?? [])).prefix(6))
            held = replaced
        } else {
            held.evidence = Array(((held.evidence ?? []) + more).prefix(6))
        }
        stances[index] = held
    }

    /// The headset's decisions folded into the record, so the Mac's copy
    /// says what the reader decided.
    static func foldReviews(model: AppModel) {
        guard let folder = model.index.folderURL,
              let reviews = CorpusRelations.StanceReviews.read(from: folder),
              !reviews.decisions.isEmpty,
              let file = CorpusRelationsBuilder.shared.file else { return }
        for (id, corpus) in file.corpora {
            guard let stances = corpus.stances,
                  stances.contains(where: { stance in
                      stance.id.flatMap { reviews.decisions[$0] }.map { $0.decision != stance.review } ?? false
                  }) else { continue }
            CorpusRelationsBuilder.shared.update(corpus: id, model: model) { corpus in
                corpus.stances = corpus.stances?.map { stance in
                    guard let id = stance.id, let decision = reviews.decisions[id] else { return stance }
                    var decided = stance
                    decided.review = decision.decision
                    decided.reviewedAt = decision.at
                    return decided
                }
            }
        }
    }

    // MARK: One pair

    private struct Window: Encodable {
        struct Line: Encodable { let element: String; let text: String }
        let section: String
        let sectionKind: String
        let lines: [Line]
    }

    private struct Passage: Encodable {
        let passageID: String
        let element: String
        let text: String
        let section: String?
    }

    private struct Reply: Decodable {
        struct Item: Decodable {
            let stance: String
            let source_quote: String?
            let source_element: String?
            let target_quote: String?
            let target_passage_id: String?
            let rationale: String?
            let confidence: Double?
        }
        let stances: [Item]?
    }

    private func read(_ pair: Pair, in corpus: CorpusRelations.Corpus, model: AppModel)
        async -> (stances: [CorpusRelations.Stance], windows: Int, dropped: Int) {
        guard let sourcePiece = corpus.pieces[pair.source], let targetPiece = corpus.pieces[pair.target],
              let source = Self.document(of: sourcePiece, model: model),
              let target = Self.document(of: targetPiece, model: model) else { return ([], 0, 0) }
        var found: [CorpusRelations.Stance] = []

        // A document's own "responds-to" link: declared, so confirmed.
        let targetRecordIDs = Set(model.epubRecords.filter { $0.folder == targetPiece.folder }.map(\.id))
        if source.links.contains(where: { $0.rel == "responds-to" && targetRecordIDs.contains($0.to) }) {
            found.append(CorpusRelations.Stance(
                from: pair.source, to: pair.target, type: "responds_to",
                point: "The source declares itself a response to the target.", source: "declared",
                review: "confirmed",
                id: CorpusRelations.Stance.stableID(from: pair.source, to: pair.target, type: "responds_to"),
                origin: "declared", confidence: 1, evidence: [], promptVersion: Self.promptVersion,
                ranAt: .now, reviewedAt: .now))
        }

        let windows = Self.windows(in: source, citing: targetPiece, target: target)
        guard !windows.isEmpty else { return (found, 0, 0) }
        let llm = OrigamiLLM.shared
        guard llm.canRespond else { return (found, windows.count, 0) }
        var dropped = 0
        for window in windows {
            if Task.isCancelled { break }
            let passages = Self.targetPassages(of: target, near: window.lines.map(\.text).joined(separator: " "))
            let message: [String: Any] = [
                "source": ["id": pair.source, "title": sourcePiece.title],
                "target": ["id": pair.target, "title": targetPiece.title],
                "section": window.section,
                "section_kind": window.sectionKind,
                "SOURCE_WINDOW": window.lines.map { ["element": $0.element, "text": $0.text] },
                "TARGET_PASSAGES": passages.map { ["passage_id": $0.passageID, "element": $0.element, "text": $0.text] },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
                  let prompt = String(data: data, encoding: .utf8) else { continue }
            let reply: (text: String, modelName: String)
            do {
                reply = try await llm.respond(instructions: Self.systemPrompt, to: prompt, transformingContent: true)
            } catch {
                log.append("   \(sourcePiece.title.prefix(40)) → \(targetPiece.title.prefix(40)): \(ReadingAI.reason(error))")
                continue
            }
            guard let start = reply.text.firstIndex(of: "{"), let end = reply.text.lastIndex(of: "}"), start < end,
                  let json = String(reply.text[start...end]).data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Reply.self, from: json) else {
                log.append("   A reply that was not the JSON asked for was set aside.")
                continue
            }
            for item in (decoded.stances ?? []).prefix(2) {
                let type = item.stance.lowercased()
                guard Self.stanceTypes.contains(type) else { continue }
                // Every quote must stand in the text, word for word.
                guard let sourceQuote = item.source_quote,
                      let sourceLine = Self.verify(sourceQuote, in: window.lines.map { ($0.element, $0.text) },
                                                   preferring: item.source_element) else { dropped += 1; continue }
                var evidence = [CorpusRelations.StanceEvidence(role: "source", quote: sourceQuote,
                                                               element: sourceLine, section: window.section)]
                if let targetQuote = item.target_quote, !targetQuote.isEmpty {
                    if let element = Self.verify(targetQuote, in: passages.map { ($0.element, $0.text) },
                                                 preferring: passages.first { $0.passageID == item.target_passage_id }?.element) {
                        evidence.append(CorpusRelations.StanceEvidence(
                            role: "target", quote: targetQuote, element: element,
                            section: passages.first { $0.element == element }?.section))
                    } else if type == "agrees_with" || type == "contradicts" {
                        dropped += 1
                        continue
                    }
                } else if type == "agrees_with" || type == "contradicts" {
                    dropped += 1
                    continue
                }
                found.append(CorpusRelations.Stance(
                    from: pair.source, to: pair.target, type: type, point: item.rationale,
                    source: "llm · " + reply.modelName, review: "proposed",
                    id: CorpusRelations.Stance.stableID(from: pair.source, to: pair.target, type: type),
                    origin: "citation", confidence: item.confidence.map { min(max($0, 0), 1) },
                    evidence: evidence, promptVersion: Self.promptVersion, ranAt: .now))
            }
        }
        return (found, windows.count, dropped)
    }

    /// A piece's text: a journal paper's own document, or a volume
    /// article cut from its volume's.
    private static func document(of piece: CorpusRelations.Piece, model: AppModel) -> LiquidDoc? {
        guard let record = model.epubRecords.first(where: { $0.folder == piece.folder }),
              let doc = model.index.byID[record.id]?.doc else { return nil }
        if piece.work == CorpusRelations.wholeWork { return doc }
        guard let bound = model.boundVolume(for: record),
              let article = bound.articles.first(where: { $0.id == piece.work }) else { return nil }
        return bound.document(for: article, in: doc)
    }

    // MARK: Context windows

    /// Every passage where the source cites the target: the citing
    /// sentence with the one before and after it in the same paragraph,
    /// overlapping windows merged, each line carrying its paragraph id;
    /// with the section it stands in and what kind of section that is.
    private static func windows(in source: LiquidDoc, citing target: CorpusRelations.Piece,
                                target targetDoc: LiquidDoc) -> [Window] {
        let wanted = ReferenceStatus.normalizedTitle(target.title)
        let targetDOI = targetDoc.doi?.lowercased()
        var keys = Set<String>()
        var shown: [String: String] = [:]
        for reference in source.references {
            let bib = BibTeXRecord.records(in: reference.bibtex).first
            let title = bib?.title ?? ""
            let doi = bib?.fields["doi"]?.lowercased()
            if (!wanted.isEmpty && ReferenceStatus.normalizedTitle(title) == wanted)
                || (targetDOI != nil && doi == targetDOI) {
                keys.insert(reference.id)
            }
            shown[reference.id] = reference.citedAs ?? reference.number.map { "[\($0)]" } ?? "[citation]"
        }
        guard !keys.isEmpty else { return [] }
        var windows: [Window] = []
        var section = ""
        for paragraph in source.body ?? [] {
            if paragraph.effectiveHeading != nil {
                section = paragraph.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            let cited = Set(Transpoint.citationKeys(in: paragraph.text))
            guard !cited.isDisjoint(with: keys) else { continue }
            let sentences = Self.sentences(paragraph.text)
            var chosen = IndexSet()
            for (index, sentence) in sentences.enumerated()
            where !Set(Transpoint.citationKeys(in: sentence)).isDisjoint(with: keys) {
                chosen.insert(integersIn: max(0, index - 1)...min(sentences.count - 1, index + 1))
            }
            if chosen.isEmpty { chosen.insert(integersIn: 0..<sentences.count) }
            let lines = chosen.map { Window.Line(element: paragraph.id, text: clean(sentences[$0], shown: shown)) }
                .filter { !$0.text.isEmpty }
            guard !lines.isEmpty else { continue }
            windows.append(Window(section: section, sectionKind: kind(of: section), lines: lines))
            if windows.count >= 4 { break }
        }
        return windows
    }

    private static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            out.append(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        }
        return out.isEmpty ? [text] : out
    }

    /// The text as the model reads it — and as its quotes are checked
    /// against: every [cite:…] token as the paper prints it.
    private static func clean(_ text: String, shown: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[cites?:([^\]]+)\]"#) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let keys = ns.substring(with: match.range(at: 1)).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            out += keys.map { shown[$0] ?? "[citation]" }.joined(separator: "; ")
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func kind(of section: String) -> String {
        let heading = section.lowercased()
        if heading.contains("introduc") { return "introduction" }
        if heading.contains("related") || heading.contains("background") || heading.contains("prior") { return "related_work" }
        if heading.contains("method") || heading.contains("approach") || heading.contains("design") { return "method" }
        if heading.contains("result") || heading.contains("evaluat") || heading.contains("finding") { return "results" }
        if heading.contains("discuss") { return "discussion" }
        if heading.contains("conclu") || heading.contains("future") { return "conclusion" }
        return "other"
    }

    // MARK: Target passages

    /// Up to three passages of the target a window most likely speaks of:
    /// its abstract, then the paragraphs of its results, discussion and
    /// conclusion, or any paragraph with a number or a verb of finding,
    /// ranked by the words they share with the window.
    private static func targetPassages(of doc: LiquidDoc, near window: String) -> [Passage] {
        let wanted = words(window)
        var candidates: [(element: String, text: String, section: String?)] = []
        if let abstract = doc.abstract, !abstract.isEmpty {
            candidates.append(("abstract", String(abstract.prefix(1500)), "Abstract"))
        }
        var section: String?
        let verbs = ["show", "find", "found", "demonstrat", "propos", "argu", "conclud", "suggest", "result"]
        for paragraph in doc.body ?? [] {
            if paragraph.effectiveHeading != nil {
                section = paragraph.displayText
                continue
            }
            let text = paragraph.displayText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard text.count > 80 else { continue }
            let heading = (section ?? "").lowercased()
            let lower = text.lowercased()
            let claimy = heading.contains("result") || heading.contains("discuss") || heading.contains("conclu")
                || text.contains(where: \.isNumber) || verbs.contains(where: lower.contains)
            if claimy { candidates.append((paragraph.id, String(text.prefix(1500)), section)) }
        }
        let ranked = candidates.enumerated().sorted { a, b in
            if a.element.element == "abstract" { return true }
            if b.element.element == "abstract" { return false }
            let x = words(a.element.text).intersection(wanted).count
            let y = words(b.element.text).intersection(wanted).count
            return x != y ? x > y : a.offset < b.offset
        }
        return ranked.prefix(3).enumerated().map { index, entry in
            Passage(passageID: "t\(index + 1)", element: entry.element.element, text: entry.element.text,
                    section: entry.element.section)
        }
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
    }

    // MARK: Quote verification

    /// Whitespace collapsed, curly quotes and dashes made plain.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The element a quote stands in, word for word — the one the model
    /// named first, then any — or nil: a quote under 25 characters, or one
    /// found nowhere, invalidates its stance.
    static func verify(_ quote: String, in lines: [(element: String, text: String)],
                       preferring element: String?) -> String? {
        let wanted = normalized(quote)
        guard wanted.count >= 25 else { return nil }
        if let element, let line = lines.first(where: { $0.element == element }),
           normalized(line.text).contains(wanted) {
            return element
        }
        if let line = lines.first(where: { normalized($0.text).contains(wanted) }) { return line.element }
        // A quote running across two sentences of one window.
        let whole = normalized(lines.map(\.text).joined(separator: " "))
        return whole.contains(wanted) ? lines.first?.element : nil
    }
}
#endif
