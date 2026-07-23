import Foundation
import FoundationModels

/// Summary & Notes for a transcript, produced on this Mac by the
/// on-device model and grounded in the transcript itself: each note
/// carries the ids of the statements that produced it, so every line of
/// the summary is a doorway back into the conversation.
///
/// The summary's store of record is an ordinary Origami document — a
/// letter that `summarizes` the transcript, AI-produced on the reader's
/// behalf, every note citing its statements — saved beside the
/// transcript, shareable like anything else, and readable by any
/// Origami app with no knowledge of this feature.
nonisolated struct TranscriptSummary {
    struct Note: Identifiable {
        var text: String
        /// Paragraph ids in the transcript that produced this note —
        /// every one verified to exist before the note is kept.
        var sources: [String]
        var id: String { text + sources.joined(separator: ",") }
    }

    var generated: Date
    /// A few sentences over the whole meeting, condensed from the notes
    /// below — the notes carry the links; this is their reading.
    var overview: String?
    var notes: [Note]

    /// The summary as an ordinary Origami document: the overview, then
    /// one paragraph per note ending in its citations, a `summarizes`
    /// link to the transcript, and `aiOnBehalf` declaring the
    /// production. The inline citations double as the machine-readable
    /// sources: `display(from:)` reads them back, and every other
    /// Origami reader shows them as live links.
    func makeDocument(for transcript: LiquidDoc, author: String,
                      id: String, fileURL: URL) -> LiquidDoc {
        var body: [LiquidDoc.Paragraph] = []
        func add(_ text: String) {
            body.append(LiquidDoc.Paragraph(id: "p\(body.count + 1)", heading: nil, text: text))
        }
        if let overview {
            add(overview)
        }
        for note in notes {
            let citations = note.sources.map { "[\(transcript.id)#\($0)]" }.joined(separator: " ")
            add("\(note.text) \(citations)")
        }
        var links = [LiquidDoc.Link(to: transcript.id, fragment: nil,
                                    rel: DocumentRelation.summarizes.rawValue)]
        links += LiquidDoc.detectedLinks(in: body)
        return LiquidDoc(format: LiquidDoc.knownFormat,
                         id: id,
                         title: "Summary — \(transcript.title)",
                         author: author,
                         created: generated,
                         body: body,
                         links: links,
                         wraps: nil,
                         date: transcript.date,
                         aiOnBehalf: true,
                         documentType: LiquidDoc.DocumentType.letter.rawValue,
                         fileURL: fileURL)
    }

    /// Reads a summary back from its document: the opening uncited
    /// paragraph is the overview; each paragraph citing the transcript
    /// is a note whose sources are the cited statement ids. Works on
    /// any summarizing document, not only ours.
    static func display(from doc: LiquidDoc, transcriptID: String) -> TranscriptSummary {
        let appendix = doc.visualMetaParagraphIDs
        var overview: String?
        var notes: [Note] = []
        for paragraph in doc.body ?? [] where !appendix.contains(paragraph.id) {
            let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var sources: [String] = []
            for match in LiquidAddress.matches(in: text)
            where LiquidAddress.canonical(match.id) == transcriptID {
                if let fragment = match.fragment, !sources.contains(fragment) {
                    sources.append(fragment)
                }
            }
            if sources.isEmpty {
                if overview == nil, paragraph.heading == nil {
                    overview = text
                }
            } else {
                // The bracketed citations become chips; the sentence
                // stands alone.
                let stripped = text
                    .replacingOccurrences(of: #"\s*\[[^\[\]]+\]"#, with: "",
                                          options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                notes.append(Note(text: stripped.isEmpty ? text : stripped,
                                  sources: sources))
            }
        }
        return TranscriptSummary(generated: doc.created, overview: overview, notes: notes)
    }
}

// MARK: - What the model returns

/// One note as the model returns it. Guided generation constrains the
/// shape; the sources are verified against the transcript's real
/// paragraphs before a note is kept.
@Generable
nonisolated struct TranscriptGeneratedNote {
    @Guide(description: "One plain sentence, in your own words, capturing something that mattered")
    var text: String
    @Guide(description: "The ids of the statements this note came from, copied exactly from the square brackets, e.g. p12")
    var sources: [String]
}

@Generable
nonisolated struct TranscriptGeneratedNotes {
    @Guide(description: "Two to five notes on this part of the meeting, in the order things happened")
    var notes: [TranscriptGeneratedNote]
}

// MARK: - The summarizer

/// Reads a transcript the way a person skims a long meeting: in passes.
/// The on-device model's context window is small, so the statements are
/// cut into chunks that fit comfortably; each chunk yields a few
/// source-linked notes; a final pass condenses the notes into a short
/// overview. A chunk the model still cannot take is split in half and
/// read again, down to a single statement.
@MainActor
enum TranscriptSummarizer {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A whole part of the transcript declined by the model — counted
    /// and skipped, never fatal on its own.
    private struct PartDeclined: Error {}

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// The model, in its content-transformation stance: summarizing the
    /// reader's own material is exactly what the permissive guardrails
    /// exist for — ordinary conversation trips the default ones far
    /// too easily.
    private static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// Whether Summary & Notes applies: the document declares itself a
    /// transcript, or reads as one — statements with speakers.
    nonisolated static func canSummarize(_ doc: LiquidDoc) -> Bool {
        doc.documentType == LiquidDoc.DocumentType.transcript.rawValue
            || (doc.body ?? []).contains { $0.speaker != nil }
    }

    /// Whether the failure was the model declining (guardrails or an
    /// outright refusal) — recoverable by skipping the offending part.
    /// Both error surfaces are checked; the SDK has carried two.
    private static func isRefusal(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError {
            if case .guardrailViolation = error { return true }
            if case .refusal = error { return true }
        }
        if let error = error as? LanguageModelError {
            if case .guardrailViolation = error { return true }
            if case .refusal = error { return true }
        }
        return false
    }

    /// Whether the failure was the context window overflowing —
    /// recoverable by splitting the part and reading each half.
    private static func isContextOverflow(_ error: Error) -> Bool {
        if let error = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = error { return true }
        if let error = error as? LanguageModelError,
           case .contextSizeExceeded = error { return true }
        return false
    }

    /// One statement as the model sees it: its paragraph id in square
    /// brackets, then the text (which already carries "Name: …").
    private struct Item {
        let id: String
        var line: String
    }

    /// The whole read: chunk, note each chunk, verify every source,
    /// keep transcript order, then condense an overview from the notes.
    /// `progress` narrates the passes for the reader.
    static func summarize(_ doc: LiquidDoc,
                          progress: @escaping @MainActor (String) -> Void)
    async throws -> TranscriptSummary {
        guard isAvailable else {
            throw Failure(message: "Summary & Notes uses the on-device model; enable Apple Intelligence to run it.")
        }
        let items = statements(of: doc)
        guard !items.isEmpty else {
            throw Failure(message: "There is nothing in this transcript to summarize.")
        }
        let validIDs = Set(items.map(\.id))
        let chunks = chunk(items)
        var notes: [TranscriptSummary.Note] = []
        // A declined part costs only itself: the rest of the meeting is
        // still read, and the refusals are reported only when nothing
        // at all came through.
        var refusedParts = 0
        for (index, part) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(chunks.count > 1
                     ? "Reading part \(index + 1) of \(chunks.count)…"
                     : "Reading the transcript…")
            do {
                notes += try await readNotes(for: part, validIDs: validIDs)
            } catch where isRefusal(error) || error is PartDeclined {
                // A refusal is often sampling luck: one more try before
                // the part is skipped.
                progress(chunks.count > 1
                         ? "Part \(index + 1) declined — trying it again…"
                         : "Declined — trying again…")
                do {
                    notes += try await readNotes(for: part, validIDs: validIDs)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    refusedParts += 1
                }
            }
        }
        // Transcript order, by each note's earliest source; duplicate
        // sentences (chunk edges retell things) collapse to one.
        let position = Dictionary(uniqueKeysWithValues:
            items.enumerated().map { ($1.id, $0) })
        notes.sort {
            ($0.sources.compactMap { position[$0] }.min() ?? .max)
                < ($1.sources.compactMap { position[$0] }.min() ?? .max)
        }
        var seen: Set<String> = []
        notes = notes.filter {
            seen.insert($0.text.lowercased().trimmingCharacters(in: .whitespaces)).inserted
        }
        guard !notes.isEmpty else {
            throw Failure(message: refusedParts > 0
                ? "Apple Intelligence declined to summarize this conversation — its safety guardrails read something here as sensitive. Trying again sometimes passes."
                : "No notes grounded in the transcript came back — try again.")
        }
        var overview: String?
        if notes.count > 1 {
            try Task.checkCancellation()
            progress("Writing the overview…")
            // The overview is a reading of the notes; losing it never
            // costs the notes themselves.
            overview = try? await condense(notes)
        }
        return TranscriptSummary(generated: .now, overview: overview, notes: notes)
    }

    // MARK: The statements

    /// Every body paragraph with words, the Visual-Meta appendix
    /// excluded, labeled by its id so the model can cite it.
    private static func statements(of doc: LiquidDoc) -> [Item] {
        let appendix = doc.visualMetaParagraphIDs
        return (doc.body ?? [])
            .filter { !appendix.contains($0.id) }
            .compactMap { paragraph in
                let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return Item(id: paragraph.id, line: "[\(paragraph.id)] \(text)")
            }
    }

    // MARK: Chunking

    /// Character budget per model pass. The on-device window is about
    /// 4096 tokens shared by the instructions, the statements, and the
    /// reply; ~9000 characters of transcript keeps well inside it, and
    /// the overflow retry below covers the estimate ever being wrong.
    private static let chunkBudget = 9000

    /// Statements gathered greedily up to the budget. A single
    /// statement longer than the whole budget travels alone, cut to fit
    /// — its opening carries its sense, and its id stays citable.
    private static func chunk(_ items: [Item]) -> [[Item]] {
        var chunks: [[Item]] = []
        var current: [Item] = []
        var cost = 0
        for var item in items {
            if item.line.count > chunkBudget {
                item.line = String(item.line.prefix(chunkBudget))
            }
            if !current.isEmpty, cost + item.line.count > chunkBudget {
                chunks.append(current)
                current = []
                cost = 0
            }
            current.append(item)
            cost += item.line.count + 1
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: One pass

    private static let instructions = """
        You are reading part of a meeting transcript. Each statement \
        begins with its id in square brackets, like [p12], followed by \
        the speaker's name and what they said.
        Write two to five notes capturing what mattered in this part: \
        decisions, plans, questions raised, disagreements, and anything \
        a participant would want remembered. Each note is one plain \
        sentence in your own words. For each note, list the ids of the \
        statements it came from, copied exactly from their brackets — \
        never invent an id.
        """

    /// Notes for one chunk. The window can still overflow — long
    /// statements, a verbose reply — so an overflowing chunk is split
    /// in half and each half read on its own, down to one statement,
    /// whose text is then cut to fit.
    private static func readNotes(for part: [Item], validIDs: Set<String>)
    async throws -> [TranscriptSummary.Note] {
        try Task.checkCancellation()
        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let material = part.map(\.line).joined(separator: "\n")
            let response = try await session.respond(to: material,
                                                     generating: TranscriptGeneratedNotes.self)
            return validated(response.content.notes, against: validIDs)
        } catch where isContextOverflow(error) {
            if part.count > 1 {
                // Each half reads on its own, and a half that is
                // declined costs only itself.
                let mid = part.count / 2
                var notes: [TranscriptSummary.Note] = []
                var refusals = 0
                for half in [Array(part[..<mid]), Array(part[mid...])] {
                    do {
                        notes += try await readNotes(for: half, validIDs: validIDs)
                    } catch where isRefusal(error) {
                        refusals += 1
                    }
                }
                if notes.isEmpty, refusals == 2 {
                    throw PartDeclined()
                }
                return notes
            }
            if var item = part.first, item.line.count > 1000 {
                item.line = String(item.line.prefix(item.line.count / 2))
                return try await readNotes(for: [item], validIDs: validIDs)
            }
            throw error
        }
    }

    /// Grounding: a note survives with the sources that verify — ids
    /// normalized ("[p12]", "p12", or a bare "12" all find p12) and
    /// checked against the transcript's real paragraphs. A note whose
    /// every source fails is dropped: an unlinked summary line is
    /// exactly what this view refuses to show.
    private static func validated(_ generated: [TranscriptGeneratedNote],
                                  against validIDs: Set<String>) -> [TranscriptSummary.Note] {
        generated.compactMap { note in
            let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var kept: [String] = []
            for raw in note.sources {
                let cleaned = raw.trimmingCharacters(
                    in: CharacterSet(charactersIn: "[]# ").union(.whitespaces))
                let candidate: String? = if validIDs.contains(cleaned) {
                    cleaned
                } else if Int(cleaned) != nil, validIDs.contains("p\(cleaned)") {
                    "p\(cleaned)"
                } else {
                    validIDs.first { $0.caseInsensitiveCompare(cleaned) == .orderedSame }
                }
                if let candidate, !kept.contains(candidate) {
                    kept.append(candidate)
                }
            }
            guard !kept.isEmpty else { return nil }
            return TranscriptSummary.Note(text: text, sources: Array(kept.prefix(4)))
        }
    }

    // MARK: The overview

    /// A few sentences over the whole meeting, written from the notes —
    /// short enough to always fit one pass.
    private static func condense(_ notes: [TranscriptSummary.Note]) async throws -> String {
        let list = notes.map(\.text).joined(separator: "\n")
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: "These are notes from one meeting's transcript. Write a two to three sentence summary of the meeting. Reply with the summary alone.\n\n\(String(list.prefix(6000)))")
        let overview = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !overview.isEmpty else {
            throw Failure(message: "The model offered no overview.")
        }
        return overview
    }
}
