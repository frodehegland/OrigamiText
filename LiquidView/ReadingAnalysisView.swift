import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The AI group's three readings of the open book — Summary, Proposals,
/// Issues — run on this Mac's model only; no text leaves it. Each
/// prompt is the reader's own, editable in Settings ▸ AI.
enum ReadingAnalysisKind: String, CaseIterable, Identifiable {
    case summary, proposals, issues

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .summary: "AI"
        case .proposals: "Proposals"
        case .issues: "Issues"
        }
    }

    var help: String {
        switch self {
        case .summary:
            "The book in the plainest language, with its names and key terms — each a click to find it in the text"
        case .proposals:
            "What the document asks the reader to accept — its main proposal, plainly stated"
        case .issues:
            "An honest reviewer's pass: the logic, the facts, then the structure and what is missing"
        }
    }

    var promptKey: String {
        switch self {
        case .summary: AppSettings.aiReadingSummaryPromptKey
        case .proposals: AppSettings.aiReadingProposalsPromptKey
        case .issues: AppSettings.aiReadingIssuesPromptKey
        }
    }

    var defaultPrompt: String {
        switch self {
        case .summary:
            """
            You are summarizing a document for a reader who wants the \
            plainest possible account of it. Write one short paragraph — \
            four to six sentences, everyday words, no jargon, no praise — \
            saying what the document is about, what it does, and what it \
            concludes. Then list the names of people the document mentions \
            or builds on, and the key terms a reader would use to find \
            their way around it. Only include names and terms that \
            actually appear in the document's text, spelled exactly as \
            they appear there.
            """
        case .proposals:
            """
            State the document's main proposal — the central claim or call \
            it asks the reader to accept — in one or two plain sentences. \
            Then, if the document carries secondary proposals, list up to \
            three, each in one sentence. Ground every proposal in what the \
            text actually argues: do not invent, soften, or improve it. If \
            the document proposes nothing (it only surveys or describes), \
            say so plainly.
            """
        case .issues:
            """
            Read the document as a careful, honest reviewer. Report in \
            three parts, in this order. 1. Logic: contradictions, circular \
            arguments, conclusions that outrun the evidence, or \
            unsupported leaps — name the specific passage each issue lives \
            in. 2. Factual correctness: claims that are wrong or doubtful \
            on their face, judged only from what you know — say plainly \
            when you are unsure. 3. Structure: what the paper's shape \
            obscures, and anything important left out or missing — an \
            unaddressed counterargument, an undefined key term, missing \
            limitations, or an evaluation the claims would need. Be \
            specific and brief; where a part has no issues, say so rather \
            than inventing any.
            """
        }
    }

    /// The prompt as the reader has it — Settings ▸ AI — or the default.
    var prompt: String {
        let stored = (UserDefaults.standard.string(forKey: promptKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? defaultPrompt : stored
    }
}

/// What one analysis returned: the prose always; names and keywords
/// when the kind is Summary.
struct ReadingAnalysisResult: Sendable {
    var text: String
    var names: [String] = []
    var keywords: [String] = []
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

    var result: ReadingAnalysisResult {
        ReadingAnalysisResult(text: text, names: names, keywords: keywords)
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
    @Guide(description: "The summary paragraph, in the plainest everyday language")
    var summary: String
    @Guide(description: "Up to ten names of people the document mentions or builds on, spelled exactly as the text spells them")
    var names: [String]
    @Guide(description: "Up to ten key terms a reader would search this document by, spelled exactly as the text spells them")
    var keywords: [String]
}
#endif

/// Runs one analysis over the open book's structured document, on the
/// on-device model in its content-transformation stance (reading the
/// reader's own material is what the permissive guardrails exist for).
/// The document is capped to the transcript summarizer's proven budget
/// and halved again on overflow — a basic analysis reads the paper's
/// front matter and body, not necessarily every appendix. Proposals and
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
            let material = corpus(of: doc, cap: cap)
            let session = LanguageModelSession(
                model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                instructions: kind.prompt)
            do {
                if kind == .summary {
                    let response = try await session.respond(
                        to: material, generating: GeneratedReadingSummary.self)
                    return ReadingAnalysisResult(
                        text: response.content.summary
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        names: response.content.names.filter { !$0.isEmpty },
                        keywords: response.content.keywords.filter { !$0.isEmpty })
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
    /// prose rather than failing; Proposals and Issues stream.
    private static func runOnSelectedModel(
        _ kind: ReadingAnalysisKind, on doc: LiquidDoc,
        onPartial: @escaping @MainActor (String) -> Void)
        async throws -> ReadingAnalysisResult {
        let material = corpus(of: doc, cap: 24_000)
        if kind == .summary {
            let ask = material + """


                Answer ONLY with one JSON object, no other words: \
                {"summary": "the summary", "names": ["..."], "keywords": ["..."]}
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
            text: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            names: (object["names"] as? [String] ?? []).filter { !$0.isEmpty },
            keywords: (object["keywords"] as? [String] ?? []).filter { !$0.isEmpty })
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                if let dismissed {
                    dismissable(block, dismissed: dismissed)
                } else {
                    blockView(block)
                }
            }
        }
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

    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .highContrast }

    @State private var result: ReadingAnalysisResult?
    @State private var created: Date?
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.displayName)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("On this Mac only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        model.readingAnalysisKind = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Back to the reading")
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
                    // The analysis is kept with the book; the reader
                    // decides when it should be redone or forgotten.
                    HStack(spacing: 16) {
                        Button("Regenerate") {
                            Task { await run(regenerate: true) }
                        }
                        .buttonStyle(.link)
                        .help("Read the document again and replace this analysis")
                        Button("Remove") {
                            if let book = model.openEPUB {
                                model.removeAnalysis(kind, forBook: book)
                            }
                            model.readingAnalysisKind = nil
                        }
                        .buttonStyle(.link)
                        .help("Delete this analysis without regenerating it")
                        if let created {
                            Text("Generated \(created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                        Text("Reading the document — the on-device model can take a minute on a long paper…")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("The prompt is yours — Settings ▸ AI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(readerTheme.background(for: colorScheme) ?? Color(nsColor: .textBackgroundColor))
        .task(id: kind) { await run() }
    }

    /// A titled run of clickable terms; each returns to the page and
    /// runs Find in the book on those words.
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
                        model.showFindFold(term: term)
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
            result = stored.result
            created = stored.created
            dismissedBlocks = Set(stored.dismissed ?? [])
            return
        }
        do {
            let fresh = try await ReadingAnalyzer.run(kind, on: doc) { text in
                partial = text
            }
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
