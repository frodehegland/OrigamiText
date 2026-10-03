import SwiftUI
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The AI group's two readings of the open book — Summary and
/// Issues — run on this Mac's model only; no text leaves it. Each
/// prompt is the reader's own, editable in Settings ▸ AI.
enum ReadingAnalysisKind: String, CaseIterable, Identifiable {
    case summary, issues

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .summary: "AI"
        case .issues: "Issues"
        }
    }

    var help: String {
        switch self {
        case .summary:
            "The book in the plainest language, with its names and key terms — each a click to find it in the text"
        case .issues:
            "An honest reviewer's pass: the logic, the facts, then the structure and what is missing"
        }
    }

    var promptKey: String {
        switch self {
        case .summary: AppSettings.aiReadingSummaryPromptKey
        case .issues: AppSettings.aiReadingIssuesPromptKey
        }
    }

    var defaultPrompt: String {
        switch self {
        case .summary:
            """
            You are summarizing a document for a reader who wants the \
            plainest possible account of it. The material gives the \
            paper's abstract, INTRODUCTION and CONCLUSION first, each \
            named, then the rest of the paper. Weigh the introduction and \
            the conclusion above everything else: the introduction is \
            where a paper says what it sets out to do, the conclusion is \
            where it says what it found. Use the rest of the paper only to \
            understand and check them. First state the paper's aim clearly \
            — what it sets out to do or answer — in one or two plain \
            sentences. Then state clearly what it concludes — its finding \
            or answer, not its topic — in one or two plain sentences; if \
            the paper reaches no clear conclusion, say so. Then tell the \
            reader that there is a lot more to the paper, and indicate what \
            else they will learn if they read the rest — as a scope, not as \
            specifics: the kinds of things it covers (for example its \
            method, its data, how it evaluates, its examples, the work it \
            builds on, its limitations), in one or two sentences, drawn \
            from THE REST OF THE PAPER and its SECTIONS. Do not repeat \
            the aim or the conclusion there. Then write one \
            short paragraph — four to six sentences, everyday words, no \
            jargon, no praise — saying what the document is about and what \
            it does. Then list the names of people the document mentions \
            or builds on, and the key terms a reader would use to find \
            their way around it. Only include names and terms that \
            actually appear in the document's text, spelled exactly as \
            they appear there. Finally, make a short glossary: the terms \
            the paper introduces, and the ordinary words it uses in a \
            non-standard way, each with what it means in this paper in one \
            plain sentence, and whether the paper coins it or uses an \
            existing word in its own way. Leave out terms used in their \
            usual sense; if there are none, give none.
            """
        case .issues:
            """
            You are helping a knowledgeable reader engage critically with \
            a published, peer-reviewed paper. Your role is a reading aid, \
            not a gatekeeper: the paper has passed review and is written \
            for an expert audience, so do not fault it for assuming \
            background knowledge, using field-standard terms without \
            definition, or leaving unstated what such a reader can supply \
            themselves. Flag only issues substantive enough to change how \
            an informed reader would weigh the paper's claims. Report in \
            three parts, in this order. 1. Logic: contradictions, circular \
            arguments, conclusions that outrun the evidence, or \
            unsupported leaps — name the specific passage each issue lives \
            in. 2. Factual correctness: claims that are wrong or doubtful \
            on their face, judged only from what you know — say plainly \
            when you are unsure. 3. Structure: what the paper's shape \
            obscures, and anything genuinely missing for an expert reader \
            — an unaddressed counterargument that materially weakens the \
            case, a term the paper coins but never pins down, or \
            limitations or an evaluation the central claims still need. \
            Be specific and brief; where a part has no issues, say so \
            rather than inventing any — with a strong published paper, \
            sparse or empty parts are the expected result, not a failure.
            """
        }
    }

    /// The Summary's relevance subject — Settings ▸ AI, "Hypertext" by
    /// default for the conference at hand. Empty leaves the sentence out.
    static var relevanceTopic: String {
        (UserDefaults.standard.string(forKey: AppSettings.aiRelevanceTopicKey)
            ?? "Hypertext")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prompt as the reader has it — Settings ▸ AI — or the default.
    /// The Summary carries one more ask, appended at run time so editing
    /// the prompt never loses it: a sentence on the document's relevance
    /// to the reader's subject of the moment.
    var prompt: String {
        let stored = (UserDefaults.standard.string(forKey: promptKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = stored.isEmpty ? defaultPrompt : stored
        if self == .summary {
            let topic = Self.relevanceTopic
            if !topic.isEmpty {
                prompt += """
                 Immediately after the summary paragraph, add one more \
                sentence stating the document's relevance to \(topic) — \
                plainly, grounded in what the text actually does; if it \
                bears no real relation to \(topic), say so in that sentence.
                """
            }
        }
        return prompt
    }
}

/// Edit Prompt: Settings opened on its AI tab, where every AI prompt —
/// the reading's and the library's — is written.
struct EditPromptButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Regenerate and Remove's light style: small grey words.
        Button("Edit Prompt") {
            model.settingsTab = .ai
            openSettings()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Open Settings ▸ AI, where this prompt is written")
    }
}

/// What one analysis returned: the prose always; names and keywords
/// when the kind is Summary.
struct ReadingAnalysisResult: Sendable {
    var text: String
    var names: [String] = []
    var keywords: [String] = []
    var glossary: [ReadingGlossaryEntry] = []
}

/// One term in the Summary's glossary: a word the paper introduces, or
/// an ordinary word it uses in its own way, with what it means *here*.
nonisolated struct ReadingGlossaryEntry: Codable, Sendable, Hashable {
    var term: String
    var meaning: String
    /// True for a term the paper coins; false for an existing word it
    /// uses in a non-standard way.
    var introduced: Bool
}

/// One kept analysis, as stored: the result, when it was made, and —
/// for Issues — which blocks the reader has dismissed as not real
/// issues (by block index; regenerating clears them with the text).
nonisolated struct StoredReadingAnalysis: Codable, Sendable {
    var text: String
    var names: [String] = []
    var keywords: [String] = []
    var created: Date
    var dismissed: [Int]? = nil
    /// Optional, so analyses kept before the glossary still load.
    var glossary: [ReadingGlossaryEntry]? = nil

    var result: ReadingAnalysisResult {
        ReadingAnalysisResult(text: text, names: names, keywords: keywords,
                              glossary: glossary ?? [])
    }
}

/// Analyses live beside the unpacked books the way annotations do: one
/// JSON per analyzed book, `<address>.analyses.json`, keyed by kind. An
/// analysis is kept until the reader regenerates or removes it.
nonisolated enum ReadingAnalysisStore {

    static func fileURL(for address: String, in folder: URL) -> URL {
        folder.appendingPathComponent(address + ".analyses.json")
    }

    static func load(for address: String, in folder: URL) -> [String: StoredReadingAnalysis] {
        guard let data = try? Data(contentsOf: fileURL(for: address, in: folder)),
              let stored = try? JSONDecoder().decode(
                  [String: StoredReadingAnalysis].self, from: data)
        else { return [:] }
        return stored
    }

    /// Writes the file, or removes it when the last analysis is gone.
    static func save(_ analyses: [String: StoredReadingAnalysis],
                     for address: String, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = fileURL(for: address, in: folder)
        guard !analyses.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(analyses) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

#if canImport(FoundationModels)
/// The Summary's guided shape: the model must return the paragraph and
/// the two lists — nothing to parse, nothing to drift.
@Generable
nonisolated struct GeneratedReadingSummary {
    @Guide(description: "The paper's aim — what it sets out to do or answer — in one or two plain sentences, taken above all from its introduction")
    var aim: String
    @Guide(description: "What the paper concludes — its finding or answer — in one or two plain sentences, taken above all from its conclusion")
    var conclusion: String
    @Guide(description: "One or two sentences telling the reader there is a lot more to the paper, and the scope of what else they will learn by reading the rest — the kinds of things it covers, not its specific results")
    var restOfPaper: String
    @Guide(description: "The summary paragraph, in the plainest everyday language")
    var summary: String
    @Guide(description: "Up to ten names of people the document mentions or builds on, spelled exactly as the text spells them")
    var names: [String]
    @Guide(description: "Up to ten key terms a reader would search this document by, spelled exactly as the text spells them")
    var keywords: [String]
    @Guide(description: "Up to eight terms the paper introduces, or ordinary words it uses in a non-standard way, each with what it means in this paper; empty when there are none")
    var glossary: [GeneratedGlossaryEntry]
}

/// One glossary entry as the model writes it.
@Generable
nonisolated struct GeneratedGlossaryEntry {
    @Guide(description: "The term, spelled exactly as the text spells it")
    var term: String
    @Guide(description: "What the term means in this paper, in one plain sentence")
    var meaning: String
    @Guide(description: "True when the paper coins the term; false when it is an existing word the paper uses in its own way")
    var introduced: Bool
}
#endif

/// Runs one analysis over the open book's structured document, on the
/// on-device model in its content-transformation stance (reading the
/// reader's own material is what the permissive guardrails exist for).
/// The document is capped to the transcript summarizer's proven budget
/// and halved again on overflow — a basic analysis reads the paper's
/// front matter and body, not necessarily every appendix. Issues
/// Issues stream, so the reply appears as it is written.
@MainActor
enum ReadingAnalyzer {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The document's words, Visual-Meta appendix excluded, capped.
    static func corpus(of doc: LiquidDoc, cap: Int) -> String {
        let appendix = doc.visualMetaParagraphIDs
        var text = (doc.body ?? [])
            .filter { !appendix.contains($0.id) }
            .map(\.text)
            .joined(separator: "\n\n")
        if text.count > cap {
            text = String(text.prefix(cap))
                + "\n\n[The document continues; the reading was cut here to fit the on-device model.]"
        }
        return text
    }

    /// What the Summary reads: the paper's abstract, introduction and
    /// conclusion first, each named, then the rest of the text as far
    /// as the cap allows. A paper states its aim at the start and its
    /// finding at the end; read front to back and cut to fit, the
    /// conclusion is the part the model never saw. The three named parts
    /// share up to two thirds of the cap; the rest fills what is left.
    static func summaryCorpus(of doc: LiquidDoc, cap: Int) -> String {
        let appendix = doc.visualMetaParagraphIDs
        let body = (doc.body ?? []).filter { !appendix.contains($0.id) }

        // A section: its heading and everything up to the next heading
        // of the same or a higher level.
        func section(matching pattern: String, last: Bool) -> Range<Int>? {
            let starts = body.indices.filter { index in
                guard body[index].heading != nil else { return false }
                let title = body[index].text
                    .replacingOccurrences(of: #"^[\d.\s]+"#, with: "", options: .regularExpression)
                return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            guard let start = last ? starts.last : starts.first,
                  let level = body[start].heading else { return nil }
            var end = start + 1
            while end < body.count, (body[end].heading ?? Int.max) > level { end += 1 }
            return (start + 1)..<end
        }
        func words(_ range: Range<Int>?) -> String {
            guard let range else { return "" }
            return body[range].map(\.text).joined(separator: "\n\n")
        }
        func capped(_ text: String, _ limit: Int) -> String {
            text.count > limit ? String(text.prefix(limit)) + " […]" : text
        }

        let introduction = section(
            matching: #"^(introduction|motivation|background and motivation|overview)\b"#,
            last: false)
        let conclusion = section(
            matching: #"^(conclusions?|concluding remarks|summary and conclusions?|discussion and conclusions?|final remarks|closing remarks)\b"#,
            last: true)
        let abstract = (doc.abstract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let share = cap / 3
        var parts: [String] = []
        if !abstract.isEmpty { parts.append("ABSTRACT\n" + capped(abstract, share / 2)) }
        if introduction != nil {
            parts.append("INTRODUCTION — where the paper states its aim\n"
                         + capped(words(introduction), share))
        }
        if conclusion != nil {
            parts.append("CONCLUSION — what the paper finds\n"
                         + capped(words(conclusion), share))
        }
        // Nothing to put first: the plain reading, front to back.
        guard introduction != nil || conclusion != nil else { return corpus(of: doc, cap: cap) }

        let used = Set((introduction.map(Array.init) ?? []) + (conclusion.map(Array.init) ?? []))
        let rest = body.indices
            .filter { !used.contains($0) }
            .map { body[$0].text }
            .joined(separator: "\n\n")
        // Every section's heading, so the scope of the rest is known even
        // where its words were cut to fit.
        let headings = body.compactMap { $0.heading == nil ? nil : $0.text }
        if !headings.isEmpty {
            parts.append("SECTIONS\n" + capped(headings.joined(separator: "\n"), cap / 12))
        }
        let lead = parts.joined(separator: "\n\n")
        let room = max(0, cap - lead.count - 40)
        if room > 200 {
            parts.append("THE REST OF THE PAPER\n" + capped(rest, room))
        }
        return parts.joined(separator: "\n\n")
    }

    static func run(_ kind: ReadingAnalysisKind, on doc: LiquidDoc,
                    onPartial: @escaping @MainActor (String) -> Void)
        async throws -> ReadingAnalysisResult {
        // A selected server model (Settings ▸ AI) reads the document
        // instead — with Apple's model as the automatic fallback
        // inside respond(). Servers usually carry far larger windows.
        if OrigamiLLM.shared.selectedEndpointModel() != nil {
            return try await runOnSelectedModel(kind, on: doc, onPartial: onPartial)
        }
        #if canImport(FoundationModels)
        guard ReadingAI.isAvailable else { throw ReadingAI.Unavailable() }
        // ~9000 characters keeps well inside the on-device window with
        // instructions and the reply — the transcript summarizer's
        // measure. Halved again if a dense document still overflows.
        var cap = 9_000
        while cap >= 2_000 {
            let material = kind == .summary
                ? summaryCorpus(of: doc, cap: cap) : corpus(of: doc, cap: cap)
            let session = LanguageModelSession(
                model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                instructions: kind.prompt)
            do {
                if kind == .summary {
                    let response = try await session.respond(
                        to: material, generating: GeneratedReadingSummary.self)
                    return ReadingAnalysisResult(
                        text: summaryText(aim: response.content.aim,
                                          conclusion: response.content.conclusion,
                                          restOfPaper: response.content.restOfPaper,
                                          summary: response.content.summary),
                        names: response.content.names.filter { !$0.isEmpty },
                        keywords: response.content.keywords.filter { !$0.isEmpty },
                        glossary: response.content.glossary.compactMap {
                            glossaryEntry(term: $0.term, meaning: $0.meaning,
                                          introduced: $0.introduced)
                        })
                }
                var text = ""
                for try await partial in session.streamResponse(to: material) {
                    text = partial.content
                    onPartial(text)
                }
                return ReadingAnalysisResult(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch let error as LanguageModelSession.GenerationError {
                guard case .exceededContextWindowSize = error else { throw error }
                cap /= 2
            }
        }
        throw Failure(message: "The document would not fit the on-device model, even shortened.")
        #else
        throw ReadingAI.Unavailable()
        #endif
    }

    /// The analysis on the chosen server model. The Summary's
    /// structure (names, keywords) comes by JSON prompting with one
    /// retry — guided generation is Apple's alone — degrading to plain
    /// prose rather than failing; Issues streams.
    private static func runOnSelectedModel(
        _ kind: ReadingAnalysisKind, on doc: LiquidDoc,
        onPartial: @escaping @MainActor (String) -> Void)
        async throws -> ReadingAnalysisResult {
        let material = kind == .summary
            ? summaryCorpus(of: doc, cap: 24_000) : corpus(of: doc, cap: 24_000)
        if kind == .summary {
            let ask = material + """


                Answer ONLY with one JSON object, no other words: \
                {"aim": "the paper's aim", "conclusion": "what it concludes", "restOfPaper": "the scope of what else the rest of the paper covers", "summary": "the summary", "names": ["..."], "keywords": ["..."], "glossary": [{"term": "...", "meaning": "what it means in this paper", "introduced": true}]}
                """
            var (text, _) = try await OrigamiLLM.shared.respond(
                instructions: kind.prompt, to: ask)
            for attempt in 0..<2 {
                if let parsed = summaryJSON(text) { return parsed }
                guard attempt == 0 else { break }
                (text, _) = try await OrigamiLLM.shared.respond(
                    instructions: kind.prompt,
                    to: ask + "\n\nYour previous answer was not valid JSON. Answer only the JSON object.")
            }
            // The words still count when the shape didn't come.
            return ReadingAnalysisResult(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let (text, _) = try await OrigamiLLM.shared.respond(
            instructions: kind.prompt, to: material, onPartial: onPartial)
        return ReadingAnalysisResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The Summary as the reader sees it: the paper's aim and its
    /// conclusion first, each named, then the scope of what the rest of
    /// the paper holds, then the plain-language paragraph. A part the
    /// model left empty is left out rather than printed bare.
    static func summaryText(aim: String, conclusion: String, restOfPaper: String = "",
                            summary: String) -> String {
        func clean(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts: [String] = []
        if !clean(aim).isEmpty { parts.append("**Aim:** " + clean(aim)) }
        if !clean(conclusion).isEmpty { parts.append("**Conclusion:** " + clean(conclusion)) }
        if !clean(restOfPaper).isEmpty {
            parts.append("**In the rest of the paper:** " + clean(restOfPaper))
        }
        if !clean(summary).isEmpty { parts.append(clean(summary)) }
        return parts.joined(separator: "\n\n")
    }

    /// The first and the last sentence in the paper's own text that use
    /// a glossary term — taken from the document, never from the model,
    /// so the quotations are always the paper's words. `last` is nil
    /// when the term is used in one sentence only; both are nil when
    /// the text never uses it (the model named a term it only implied).
    static func firstAndLastUse(of term: String, in doc: LiquidDoc) -> (first: String?, last: String?) {
        let appendix = doc.visualMetaParagraphIDs
        let paragraphs = (doc.body ?? [])
            .filter { $0.heading == nil && !appendix.contains($0.id) }
            .map { plainSentenceText($0.text) }
            .filter { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        func sentences(of text: String) -> [String] {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            return tokenizer.tokens(for: text.startIndex..<text.endIndex)
                .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        guard let firstParagraph = paragraphs.first,
              let first = sentences(of: firstParagraph).first else { return (nil, nil) }
        let last = paragraphs.last.flatMap { sentences(of: $0).last }
        return (first, last == first ? nil : last)
    }

    /// A body paragraph's words as a reader sees them: the format's
    /// citation tokens, link targets and emphasis marks taken out.
    static func plainSentenceText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[cites?:[^\]]+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"(?<![\w*])\*(?!\s)|(?<!\s)\*(?![\w*])"#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The model's names, keywords and glossary terms held to the paper's
    /// own text — the prompt asks for only words the text uses, and a
    /// small model does not always keep to it (a cited author, say, who
    /// stands only in the bibliography, or a name it recalled). Find runs
    /// on these words, so each must be findable:
    ///   • a term the text uses (case, accents, curly quotes and dashes
    ///     aside) stays as written;
    ///   • a person's name the text does not carry whole is found by its
    ///     surname and rewritten in the text's own spelling ("Doug
    ///     Engelbart" → "Douglas Engelbart");
    ///   • anything else is left out.
    static func verified(_ result: ReadingAnalysisResult, in doc: LiquidDoc) -> ReadingAnalysisResult {
        let appendix = doc.visualMetaParagraphIDs
        let text = ([doc.title] + (doc.body ?? [])
            .filter { !appendix.contains($0.id) }
            .map { plainSentenceText($0.text) })
            .joined(separator: "\n")
        let haystack = normalizedForMatch(text)
        func uses(_ term: String) -> Bool {
            let wanted = normalizedForMatch(term)
            return !wanted.isEmpty && haystack.contains(wanted)
        }
        var seen = Set<String>()
        func unique(_ term: String) -> Bool { seen.insert(normalizedForMatch(term)).inserted }

        // A term that matches only once quotes and dashes are folded is
        // given in the text's own spelling — Find (case and accents aside)
        // must see it exactly as printed.
        func asPrinted(_ term: String) -> String? {
            guard uses(term) else { return nil }
            if text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return term
            }
            return textSpelling(of: term, in: text)
        }
        var out = result
        out.keywords = result.keywords.compactMap { keyword -> String? in
            guard let printed = asPrinted(keyword), unique(printed) else { return nil }
            return printed
        }
        seen = []
        out.names = result.names.compactMap { name -> String? in
            if let printed = asPrinted(name) { return unique(printed) ? printed : nil }
            guard let spelled = textSpelling(ofSurnameIn: name, in: text) else { return nil }
            return unique(spelled) ? spelled : nil
        }
        // A bare surname beside the full name it belongs to says nothing
        // more — "Rubart" with "Jessica Rubart" — and is left out.
        out.names = out.names.filter { name in
            name.contains(" ") || !out.names.contains { other in
                other != name && normalizedForMatch(other).hasSuffix(" " + normalizedForMatch(name))
            }
        }
        out.glossary = result.glossary.compactMap { entry -> ReadingGlossaryEntry? in
            guard let printed = asPrinted(entry.term) else { return nil }
            var kept = entry
            kept.term = printed
            return kept
        }
        return out
    }

    /// Text folded for matching: case, accents and width aside, curly
    /// quotes and dashes as their plain forms, runs of space as one.
    private static func normalizedForMatch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
            .replacingOccurrences(of: "[\u{2018}\u{2019}\u{02BC}]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[\u{201C}\u{201D}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2010}-\u{2015}]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The text's own spelling of a term that differs from it only in its
    /// quotes, dashes or spacing: "Engelbart's" for "Engelbart’s".
    private static func textSpelling(of term: String, in text: String) -> String? {
        var pattern = ""
        for character in term {
            switch character {
            case "'", "\u{2018}", "\u{2019}", "\u{02BC}": pattern += #"['\x{2018}\x{2019}\x{02BC}]"#
            case "-", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}":
                pattern += #"[-\x{2010}-\x{2015}]"#
            case " ": pattern += #"\s+"#
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// A name the text does not carry whole, looked for by its surname:
    /// the text's own run of capitalised words ending on that surname
    /// ("Douglas C. Engelbart"), or the surname alone. Nil when the
    /// surname is not in the text either, or too short to be telling.
    private static func textSpelling(ofSurnameIn name: String, in text: String) -> String? {
        let words = name.split(whereSeparator: { $0 == " " }).map(String.init)
        guard words.count > 1, let surname = words.last?
                .trimmingCharacters(in: .punctuationCharacters),
              surname.count >= 3, surname.first?.isUppercase == true else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: surname)
        // ICU spells a code point \x{…} — a raw \u{…} would not compile.
        let pattern = #"((?:\p{Lu}[\p{L}.'\x{2019}-]*\s+){0,3})"# + escaped + #"(?![\p{L}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A glossary entry kept only when it has both a term and a meaning.
    static func glossaryEntry(term: String, meaning: String,
                              introduced: Bool) -> ReadingGlossaryEntry? {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !meaning.isEmpty else { return nil }
        return ReadingGlossaryEntry(term: term, meaning: meaning, introduced: introduced)
    }

    /// A lenient read of the summary JSON — fenced or bare, extra keys
    /// ignored. Nil when no object parses.
    private static func summaryJSON(_ text: String) -> ReadingAnalysisResult? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = object["summary"] as? String, !summary.isEmpty
        else { return nil }
        return ReadingAnalysisResult(
            text: summaryText(aim: object["aim"] as? String ?? "",
                              conclusion: object["conclusion"] as? String ?? "",
                              restOfPaper: object["restOfPaper"] as? String ?? "",
                              summary: summary),
            names: (object["names"] as? [String] ?? []).filter { !$0.isEmpty },
            keywords: (object["keywords"] as? [String] ?? []).filter { !$0.isEmpty },
            glossary: (object["glossary"] as? [[String: Any]] ?? []).compactMap {
                glossaryEntry(term: $0["term"] as? String ?? "",
                              meaning: $0["meaning"] as? String ?? "",
                              introduced: $0["introduced"] as? Bool ?? true)
            })
    }
}

/// Column View's right-hand column: a clicked term's Find beside the AI
/// reading — the sections that use it and every sentence that does, the
/// term marked — each sentence a click into the reading at that place.
/// The same matching as the page's find-fold (`OrigamiReading.folded`).
struct FindColumnView: View {
    @Environment(AppModel.self) private var model
    let term: String
    let doc: LiquidDoc
    let book: OpenEPUB
    let onClose: () -> Void

    /// The result clicked: the column shows the Scroll reading there
    /// instead of the list, until "‹ Find" goes back.
    @State private var readingAt: String?
    @State private var readingStamp = 0

    /// Headings that carry a match, each with its matching sentences.
    private var groups: [(heading: LiquidDoc.Paragraph?, hits: [LiquidDoc.Paragraph])] {
        let found = OrigamiReading.folded(doc, matching: term) ?? []
        var out: [(heading: LiquidDoc.Paragraph?, hits: [LiquidDoc.Paragraph])] = []
        var heading: LiquidDoc.Paragraph?
        var hits: [LiquidDoc.Paragraph] = []
        func flush() {
            if !hits.isEmpty { out.append((heading, hits)) }
            hits = []
        }
        for paragraph in found {
            if paragraph.heading != nil {
                flush()
                heading = paragraph
            } else {
                hits.append(paragraph)
            }
        }
        flush()
        return out
    }

    var body: some View {
        Group {
            if let paragraphID = readingAt {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Button("\u{2039} Find") { leaveReading(); readingAt = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Back to the places that use \u{201C}\(term)\u{201D}")
                        Spacer()
                        Button("Close") { leaveReading(); onClose() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Close the column")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    Divider()
                    ColumnScrollReader(book: book, paragraphID: paragraphID,
                                       stamp: readingStamp) { place in
                        // Read on in the column: Scroll or Horizontal,
                        // chosen at the foot, opens where it now stands.
                        model.pendingReaderFragment = place
                    }
                }
            } else {
                resultsList
            }
        }
        // A new term opens on its results, never on the last reading.
        .onChange(of: term) { readingAt = nil }
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Finding \u{201C}\(term)\u{201D}")
                        .font(.headline)
                    Spacer()
                    Button("Close", action: onClose)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Close the column")
                }
                let groups = groups
                if groups.isEmpty {
                    Text("The paper's text does not use these words.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 6) {
                        if let heading = group.heading {
                            Text(ReadingAnalyzer.plainSentenceText(heading.text))
                                .font(.callout.weight(.semibold))
                        }
                        ForEach(group.hits, id: \.id) { hit in
                            Button {
                                open(hit.id)
                            } label: {
                                Text(marked(ReadingAnalyzer.plainSentenceText(hit.text)))
                                    .font(.callout)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open the reading at this place")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    /// The sentence with every use of the term marked, as Find marks it.
    private func marked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        var searchStart = out.startIndex
        while searchStart < out.endIndex,
              let range = out[searchStart...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[range].backgroundColor = .orange.opacity(0.35)
            out[range].font = .callout.weight(.semibold)
            searchStart = range.upperBound
        }
        return out
    }

    /// A result clicked: the Scroll reading takes this column, landing
    /// on the paragraph — the AI stays where it is beside it. Swapped in
    /// without animation: a WebView inserted inside an animation is the
    /// macOS 27 display-cycle crash.
    private func open(_ paragraphID: String) {
        readingStamp += 1
        readingAt = paragraphID
        // The place the reading carries on from: choosing Scroll or
        // Horizontal at the foot closes the AI and opens the paper here.
        model.pendingReaderFragment = paragraphID
    }

    /// The column's reading put away: its place is no longer where the
    /// paper should open.
    private func leaveReading() {
        model.pendingReaderFragment = nil
    }
}

/// The book's Scroll reading in a column — the faithful pages in the
/// reader's own theme, fonts and size, opened on one paragraph and
/// flashed there, as a contents jump lands. The full width of the
/// column: the column is already the measure.
struct ColumnScrollReader: View {
    @Environment(AppModel.self) private var model
    let book: OpenEPUB
    let paragraphID: String
    let stamp: Int
    /// Where the reading in the column now stands — the clicked
    /// paragraph, then each heading the reader scrolls on to.
    var onPlace: (String) -> Void = { _ in }

    /// The heading the reader last reached. Reports in the first moments
    /// after a landing are the landing settling (the page re-lands once
    /// its fonts and images are in), not reading on — the exact clicked
    /// paragraph stands until the reader really scrolls.
    @State private var landedHeading: String?
    @State private var landedAt = Date.distantPast

    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    @AppStorage(AppSettings.readerBodyFontKey) private var bodyFont = ReaderStyle.defaultBodyFont
    @AppStorage(AppSettings.readerHeadingFontKey) private var headingFont = ReaderStyle.defaultHeadingFont
    @AppStorage(ThemeColorOverrides.tickKey) private var themeEditTick = 0
    @AppStorage("readingFontDelta") private var fontDelta = 3.0
    @AppStorage("readingLineSpacing") private var lineSpacing = 3.0
    @State private var chapterIndex = 0

    private var chapters: [URL] { book.chapters.isEmpty ? [book.content] : book.chapters }

    private var css: String {
        _ = themeEditTick
        return ReaderStyle.css(bodyFont: bodyFont, headingFont: headingFont,
                               theme: ReaderTheme(rawValue: themeRaw) ?? .highContrast,
                               fontDelta: fontDelta, lineSpacing: lineSpacing)
    }

    /// The chapter whose page carries the paragraph's id.
    private func chapter(containing id: String) -> Int? {
        let key = id.split(separator: "#").last.map(String.init) ?? id
        return chapters.firstIndex { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("id=\"\(key)\"")
        }
    }

    var body: some View {
        EPUBReaderView(
            book: book,
            css: css,
            content: chapters[min(max(chapterIndex, 0), chapters.count - 1)],
            chapterIndex: chapterIndex,
            chapterCount: chapters.count,
            onChapterStep: { delta in
                let next = chapterIndex + delta
                if chapters.indices.contains(next) { chapterIndex = next }
            },
            resolveEndnote: { id in model.endnoteText(inBook: book, id: id) },
            initialFragment: paragraphID,
            requestedFragment: paragraphID,
            fragmentStamp: stamp,
            onCurrentHeading: { id in
                guard !id.isEmpty else { return }
                // Still settling: note where the landing put the page.
                if Date.now.timeIntervalSince(landedAt) < 1.5 || landedHeading == nil {
                    landedHeading = id
                    return
                }
                if id != landedHeading {
                    landedHeading = id
                    onPlace(id)
                }
            })
        .onAppear {
            chapterIndex = chapter(containing: paragraphID) ?? 0
            landedAt = .now
        }
        .onChange(of: stamp) {
            landedHeading = nil
            landedAt = .now
        }
        .onChange(of: stamp) { chapterIndex = chapter(containing: paragraphID) ?? chapterIndex }
    }
}

/// The model's reply rendered as it means: headings, bullet and
/// numbered lists, and inline bold/italic — the markdown on-device
/// models habitually write — without a web view. Unknown shapes fall
/// back to plain paragraphs, so nothing is ever lost.
struct MarkdownReplyText: View {
    let text: String
    /// Dismissable blocks (the Issues reading): a click folds a block
    /// to its leading bold words — unbolded, with an ellipsis — for
    /// the reader to set aside an issue they judge not real; a click
    /// on the folded line brings it back. Nil renders plainly.
    var dismissed: Binding<Set<Int>>? = nil

    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case bullet(id: Int, text: String)
        case numbered(id: Int, number: String, text: String)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _), .bullet(let id, _),
                 .numbered(let id, _, _), .paragraph(let id, _):
                id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                if let dismissed {
                    dismissable(block, dismissed: dismissed)
                } else {
                    blockView(block)
                }
            }
        }
        // AI readings are dense prose — air between the lines.
        .lineSpacing(4)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(_, let level, let text):
            inline(text)
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .bullet(_, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(text)
            }
            .padding(.leading, 8)
        case .numbered(_, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .monospacedDigit()
                inline(text)
            }
            .padding(.leading, 8)
        case .paragraph(_, let text):
            inline(text)
        }
    }

    /// One block the reader can set aside: whole, a click folds it to
    /// its leading words with an ellipsis; folded, a click restores it.
    @ViewBuilder
    private func dismissable(_ block: Block, dismissed: Binding<Set<Int>>) -> some View {
        let isDismissed = dismissed.wrappedValue.contains(block.id)
        Group {
            if isDismissed {
                Text(collapsedLine(of: block))
                    .foregroundStyle(.secondary)
            } else {
                blockView(block)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) {
                if isDismissed {
                    dismissed.wrappedValue.remove(block.id)
                } else {
                    dismissed.wrappedValue.insert(block.id)
                }
            }
        }
        .help(isDismissed ? "Restore this issue" : "Set this issue aside — you judge it not a real one")
    }

    /// The folded line: the block's leading bold words when it opens
    /// with any (its own heading), else its first words — unbolded,
    /// trailing an ellipsis, its list marker kept.
    private func collapsedLine(of block: Block) -> String {
        let raw: String
        var marker = ""
        switch block {
        case .heading(_, _, let text): raw = text
        case .bullet(_, let text): raw = text; marker = "• "
        case .numbered(_, let number, let text): raw = text; marker = "\(number). "
        case .paragraph(_, let text): raw = text
        }
        if let range = raw.range(of: #"^\*\*[^*]+\*\*"#, options: .regularExpression) {
            let lead = String(raw[range])
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return marker + lead + " …"
        }
        let words = raw
            .replacingOccurrences(of: "**", with: "")
            .split(separator: " ")
            .prefix(6)
            .joined(separator: " ")
        return marker + words + " …"
    }

    /// The reply cut into blocks: headings, list items, and paragraphs
    /// (consecutive plain lines joined, blank lines separating).
    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                out.append(.paragraph(id: out.count,
                                      text: paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(id: out.count, level: level,
                                    text: String(line.dropFirst(level))
                                        .trimmingCharacters(in: .whitespaces)))
            } else if let range = line.range(of: #"^[-*•]\s+"#,
                                             options: .regularExpression) {
                flush()
                out.append(.bullet(id: out.count,
                                   text: String(line[range.upperBound...])))
            } else if let range = line.range(of: #"^\d{1,3}[.)]\s+"#,
                                             options: .regularExpression) {
                flush()
                let marker = line[..<range.upperBound]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
                out.append(.numbered(id: out.count, number: marker,
                                     text: String(line[range.upperBound...])))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    /// One line's inline markdown — bold, italic, code — or the plain
    /// words when it will not parse.
    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(string)
    }
}

/// The AI reading over the whole page: the analysis of the open book,
/// written while you watch. In a Summary, every name and keyword is a
/// click — it returns to the page and runs Find on those very words.
/// Close (or any mode word at the foot) returns to the reading.
struct ReadingAnalysisScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppSettings.readerThemeKey) private var themeRaw = ReaderTheme.highContrast.rawValue
    let kind: ReadingAnalysisKind

    // Edited theme colours apply live: every override write bumps this.
    @AppStorage(ThemeColorOverrides.tickKey) private var themeEditTick = 0
    private var readerTheme: ReaderTheme {
        _ = themeEditTick
        return ReaderTheme(rawValue: themeRaw) ?? .highContrast
    }

    @State private var result: ReadingAnalysisResult?
    @State private var created: Date?
    /// Column View: a clicked keyword, name or glossary term opens its
    /// Find in a column on the right, the AI reading staying in view;
    /// off, it folds the whole page to the find, as before.
    @AppStorage("aiColumnView") private var columnView = false
    /// The reader's body font, for the paper's own sentences quoted here.
    @AppStorage(AppSettings.readerBodyFontKey) private var bodyFontName = ReaderStyle.defaultBodyFont
    /// The term the right-hand column is finding, when one is open.
    @State private var columnTerm: String?
    @State private var partial = ""
    @State private var failure: String?
    /// Issues the reader has set aside, persisted with the analysis.
    @State private var dismissedBlocks: Set<Int> = []

    /// The dismissal binding, Issues only — a change lands straight in
    /// the stored analysis. Text selection yields to the click there.
    private var dismissedBinding: Binding<Set<Int>>? {
        guard kind == .issues else { return nil }
        return Binding(
            get: { dismissedBlocks },
            set: { value in
                dismissedBlocks = value
                if let book = model.openEPUB {
                    model.setAnalysisDismissed(value, kind: kind, forBook: book)
                }
            })
    }

    var body: some View {
        HStack(spacing: 0) {
            // With a term's column open the screen splits in half: the
            // AI reading on the left, the Find (or the reading itself,
            // once a result is clicked) on the right.
            analysisPane
                .frame(maxWidth: .infinity)
            if columnView, let term = columnTerm,
               let book = model.openEPUB, let doc = model.readingDoc(forBook: book) {
                Divider()
                FindColumnView(term: term, doc: doc, book: book) { columnTerm = nil }
                    .frame(maxWidth: .infinity)
            }
        }
        .background(readerTheme.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor))
        .task(id: kind) { await run() }
    }

    /// A keyword, name or glossary term clicked: its Find in the column
    /// on the right (Column View), or the whole page folded to it.
    private func openTerm(_ term: String) {
        if columnView {
            columnTerm = term
        } else {
            model.showFindFold(term: term)
        }
    }

    /// Column View's switch — the light words of the bottom line,
    /// underlined while clicks open the column.
    private var columnViewToggle: some View {
        Button("Column View") {
            columnView.toggle()
            if !columnView { columnTerm = nil }
        }
        .buttonStyle(.plain)
        .font(.caption)
        // The same grey as Regenerate and Edit Prompt either way; on is
        // told by the underline alone.
        .underline(columnView)
        .foregroundStyle(.secondary)
        .help(columnView
              ? "On: a clicked term opens its Find in a column on the right"
              : "Off: a clicked term folds the whole page to its Find — click to open in a column instead")
    }

    private var analysisPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.displayName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(.secondary)
                } else if let result {
                    if let dismissedBinding {
                        // Issues: each block a click to set aside or
                        // restore — selection yields to the judgment.
                        MarkdownReplyText(text: result.text,
                                          dismissed: dismissedBinding)
                    } else {
                        MarkdownReplyText(text: result.text)
                            .textSelection(.enabled)
                    }
                    if !result.names.isEmpty {
                        termsSection("Names", terms: result.names)
                    }
                    if !result.keywords.isEmpty {
                        termsSection("Keywords", terms: result.keywords)
                    }
                    if !result.glossary.isEmpty {
                        glossarySection(result.glossary)
                    }
                    // The analysis is kept with the book; the reader
                    // decides when it should be redone or forgotten.
                    // Light, so they never compete with the reading itself.
                    HStack(spacing: 16) {
                        Button("Regenerate") {
                            Task { await run(regenerate: true) }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Read the document again and replace this analysis")
                        Button("Remove") {
                            if let book = model.openEPUB {
                                model.removeAnalysis(kind, forBook: book)
                            }
                            model.readingAnalysisKind = nil
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Delete this analysis without regenerating it")
                        if let created {
                            Text("Generated \(created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        columnViewToggle
                        EditPromptButton()
                    }
                    .padding(.top, 8)
                } else if !partial.isEmpty {
                    // Streaming: the reply as far as it has been written.
                    MarkdownReplyText(text: partial)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Still writing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Analysing the document — the on-device model can take a minute on a long paper…")
                            .foregroundStyle(.secondary)
                    }
                }
                // With a result it stands on the Regenerate line; while
                // analysing, or when the analysis failed, it stands alone
                // at the same right edge.
                if result == nil {
                    HStack {
                        Spacer()
                        columnViewToggle
                        EditPromptButton()
                    }
                    .padding(.top, 8)
                }
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// A titled run of clickable terms; each returns to the page and
    /// runs Find in the book on those words.
    /// The AI's glossary: each term a click to find it in the text, with
    /// what it means in this paper and whether the paper coins it or
    /// uses an existing word its own way.
    private func glossarySection(_ entries: [ReadingGlossaryEntry]) -> some View {
        // The open paper, for each term's first and last use in its text.
        let doc = model.openEPUB.flatMap { model.readingDoc(forBook: $0) }
        return VStack(alignment: .leading, spacing: 18) {
            Text("Glossary")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(entries, id: \.self) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // The keywords' own chip: a click is Find, back in
                        // the document folded to the sentences around it.
                        Button {
                            openTerm(entry.term)
                        } label: {
                            Text(entry.term)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Find “\(entry.term)” in the document")
                        Text(entry.introduced ? "introduced here" : "used in its own way")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.meaning)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    // Where the paper itself uses the term: its first
                    // sentence, and its last when that is another.
                    if let doc {
                        let uses = ReadingAnalyzer.firstAndLastUse(of: entry.term, in: doc)
                        if let first = uses.first {
                            usageLine(uses.last == nil ? "Used" : "First use", first)
                        }
                        if let last = uses.last {
                            usageLine("Last use", last)
                        }
                    }
                }
            }
        }
    }

    /// One quoted sentence from the paper, under a glossary entry — in
    /// the reader's body font (Settings ▸ Reading), the paper's own type.
    private func usageLine(_ label: String, _ sentence: String) -> some View {
        (Text(label + ": ").foregroundStyle(.secondary)
            + Text("\u{201C}\(sentence)\u{201D}"))
            .font(.custom(bodyFontName, size: 15, relativeTo: .body))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 8)
    }

    private func termsSection(_ title: String, terms: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(terms, id: \.self) { term in
                    Button {
                        // The find-fold: back to the document, folded to
                        // its headings and the sentences around the term.
                        openTerm(term)
                    } label: {
                        Text(term)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Find “\(term)” in the document")
                }
            }
        }
    }

    private func run(regenerate: Bool = false) async {
        result = nil
        created = nil
        partial = ""
        failure = nil
        dismissedBlocks = []
        guard let book = model.openEPUB,
              let doc = model.readingDoc(forBook: book) else {
            failure = "Open a book first — the analysis reads the open document."
            return
        }
        // A kept analysis answers at once; Regenerate reads afresh.
        if !regenerate, let stored = model.storedAnalysis(kind, forBook: book) {
            // Checked against the paper on the way in too: an analysis kept
            // from before the check loses any name the text never uses.
            result = ReadingAnalyzer.verified(stored.result, in: doc)
            created = stored.created
            dismissedBlocks = Set(stored.dismissed ?? [])
            return
        }
        do {
            let fresh = ReadingAnalyzer.verified(
                try await ReadingAnalyzer.run(kind, on: doc) { text in partial = text },
                in: doc)
            result = fresh
            created = .now
            model.saveAnalysis(kind, result: fresh, forBook: book)
            // The chosen model wasn't reachable and Apple's answered
            // instead — said plainly, never silently (Settings ▸ AI).
            if let notice = OrigamiLLM.shared.fallbackNotice {
                OrigamiLLM.shared.fallbackNotice = nil
                model.showNote(notice)
            }
        } catch is CancellationError {
            // The reader moved on; nothing to say.
        } catch {
            failure = ReadingAI.isAvailable
                ? "The model could not read this document: \(error.localizedDescription)"
                : "The on-device model isn’t available on this Mac — the AI readings need Apple Intelligence."
        }
    }
}
