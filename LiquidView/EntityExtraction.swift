// Bulk concept and entity extraction across whole documents, local-first
// (spec kin of local-llm-support-spec.md): Apple's on-device model by
// default — guided generation guarantees the shape — or the user's
// chosen endpoint model when one is selected, falling back to Apple's.
// Large documents are read in paragraph-packed chunks sized for the
// on-device context window; a chunk that still overflows splits and
// retries, so no document is too long to finish. Results persist in the
// community folder, one file, so visionOS reads the same extractions.
#if os(macOS)
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The result

/// Everything one document yielded, merged across its chunks.
nonisolated struct DocumentExtraction: Codable, Sendable {
    var concepts: [String] = []
    var keywords: [String] = []
    var people: [String] = []
    var places: [String] = []
    var technologies: [String] = []
    var scientificTerms: [String] = []
    /// Which model read the document, and when.
    var model = ""
    var date = Date.distantPast
    var chunkCount = 0

    var isEmpty: Bool {
        concepts.isEmpty && keywords.isEmpty && people.isEmpty
            && places.isEmpty && technologies.isEmpty && scientificTerms.isEmpty
    }

    /// The categories in display order, non-empty only.
    var categories: [(name: String, items: [String])] {
        [("Concepts", concepts), ("Keywords", keywords), ("People", people),
         ("Places", places), ("Technologies", technologies),
         ("Scientific Terms", scientificTerms)]
            .filter { !$0.1.isEmpty }
    }
}

/// The extractions on disk — one file in the community folder, keyed by
/// record id, the same pattern as the publication analyses.
nonisolated struct ExtractionsFile: Codable {
    var extractions: [String: DocumentExtraction] = [:]
    static let filename = "_document-extractions.json"

    static func read(from folder: URL) -> ExtractionsFile {
        let url = folder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ExtractionsFile.self, from: data)
        else { return ExtractionsFile() }
        return file
    }

    func write(to folder: URL) {
        let url = folder.appendingPathComponent(Self.filename)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - The guided-generation shape (Apple's model)

#if canImport(FoundationModels)
/// What the model reports for one passage. Guided generation constrains
/// the output to this shape — no parsing, no malformed replies.
@Generable(description: "Entities and concepts found in a passage of an academic document.")
nonisolated struct PassageExtraction {
    @Guide(description: "Key concepts the passage defines, introduces, or leans on.",
           .maximumCount(6))
    var concepts: [String]
    @Guide(description: "Topic keywords for the passage.", .maximumCount(6))
    var keywords: [String]
    @Guide(description: "People named in the passage text.", .maximumCount(8))
    var people: [String]
    @Guide(description: "Places named in the passage.", .maximumCount(6))
    var places: [String]
    @Guide(description: "Technologies, systems, tools, or products named in the passage.",
           .maximumCount(8))
    var technologies: [String]
    @Guide(description: "Scientific or technical terms of art used in the passage.",
           .maximumCount(8))
    var scientificTerms: [String]
}
#endif

// MARK: - The extractor

nonisolated enum EntityExtractor {

    static let instructions = """
        You extract entities and concepts from passages of academic \
        documents. Report only what the passage itself contains. Use the \
        shortest natural form of each name or term. Do not invent entries; \
        an empty list is a fine answer.
        """

    /// Paragraphs packed into chunks the on-device context comfortably
    /// holds — instructions, schema, and the reply all share the window,
    /// so the passage takes well under half of it.
    static func chunks(of paragraphs: [String], budget: Int = 6500) -> [String] {
        var chunks: [String] = []
        var current = ""
        for paragraph in paragraphs {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if current.count + text.count + 2 > budget, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            // A single paragraph over budget splits at sentence-ish seams.
            if text.count > budget {
                var rest = text[...]
                while rest.count > budget {
                    let cut = rest.index(rest.startIndex, offsetBy: budget)
                    let seam = rest[..<cut].lastIndex(where: { ".!?\n".contains($0) })
                        .map { rest.index(after: $0) } ?? cut
                    chunks.append(String(rest[..<seam]))
                    rest = rest[seam...]
                }
                current = String(rest)
                continue
            }
            current += current.isEmpty ? text : "\n\n" + text
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// One document, however large: chunked, extracted chunk by chunk on
    /// the selected model (Apple's on-device model unless the user chose
    /// an endpoint; endpoint failure falls back to Apple's, matching
    /// OrigamiLLM), merged, capped. `excluding` drops the paper's own
    /// byline from People.
    @MainActor
    static func extract(paragraphs: [String], excluding authors: [String] = [])
        async throws -> DocumentExtraction {
        let pieces = chunks(of: paragraphs)
        var merged: [String: [String: Int]] = [:]   // category → item(lower) → count
        var canonical: [String: String] = [:]        // item(lower) → first-seen casing
        var modelName = ""

        func fold(_ items: [String], into category: String) {
            for raw in items {
                let item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard item.count > 1, item.count <= 60 else { continue }
                let key = item.lowercased()
                merged[category, default: [:]][key, default: 0] += 1
                if canonical[key] == nil { canonical[key] = item }
            }
        }

        for piece in pieces {
            try Task.checkCancellation()
            do {
                let (result, model) = try await extractChunk(piece)
                modelName = model
                fold(result.concepts, into: "concepts")
                fold(result.keywords, into: "keywords")
                fold(result.people, into: "people")
                fold(result.places, into: "places")
                fold(result.technologies, into: "technologies")
                fold(result.scientificTerms, into: "scientificTerms")
            } catch let error where isContextOverflow(error) {
                // Still too long for the window: split and take both halves.
                let halves = split(piece)
                for half in halves {
                    if let (result, model) = try? await extractChunk(half) {
                        modelName = model
                        fold(result.concepts, into: "concepts")
                        fold(result.keywords, into: "keywords")
                        fold(result.people, into: "people")
                        fold(result.places, into: "places")
                        fold(result.technologies, into: "technologies")
                        fold(result.scientificTerms, into: "scientificTerms")
                    }
                }
            } catch let error where isGuardrail(error) {
                // A passage the model declines to read — skip it, keep going.
                continue
            }
        }

        let bylines = Set(authors.flatMap { author in
            author.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
        })
        func top(_ category: String, cap: Int = 20, dropBylines: Bool = false) -> [String] {
            (merged[category] ?? [:])
                .filter { !dropBylines || !bylines.contains($0.key) }
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(cap)
                .compactMap { canonical[$0.key] }
        }
        var extraction = DocumentExtraction()
        extraction.concepts = top("concepts")
        extraction.keywords = top("keywords")
        extraction.people = top("people", dropBylines: true)
        extraction.places = top("places")
        extraction.technologies = top("technologies")
        extraction.scientificTerms = top("scientificTerms")
        extraction.model = modelName
        extraction.date = .now
        extraction.chunkCount = pieces.count
        return extraction
    }

    private static func split(_ text: String) -> [String] {
        guard text.count > 800 else { return [text] }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let seam = text[..<middle].lastIndex(where: { ".!?\n".contains($0) })
            .map { text.index(after: $0) } ?? middle
        return [String(text[..<seam]), String(text[seam...])]
    }

    /// One chunk on the selected model. An endpoint answers JSON we
    /// parse leniently; Apple's model answers through guided generation,
    /// which cannot be malformed.
    @MainActor
    private static func extractChunk(_ passage: String)
        async throws -> (PassageValues, model: String) {
        if let (endpoint, model) = OrigamiLLM.shared.selectedEndpointModel() {
            do {
                let prompt = """
                    Extract from the passage below. Reply with ONLY a JSON object, \
                    no prose, with these keys, each an array of short strings: \
                    "concepts", "keywords", "people", "places", "technologies", \
                    "scientificTerms". Empty arrays are fine.

                    PASSAGE:
                    \(passage)
                    """
                let text = try await ChatCompletionsClient.respond(
                    base: endpoint.base, model: model,
                    key: OrigamiLLM.shared.apiKey(for: endpoint.base),
                    instructions: instructions, prompt: prompt)
                if let values = PassageValues(lenientJSON: text) {
                    return (values, "\(endpoint.hostLabel) \u{00B7} \(model)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Fall through to Apple's model, as OrigamiLLM does.
            }
        }
        return (try await appleExtract(passage), "Apple\u{2019}s built-in model")
    }

    @MainActor
    private static func appleExtract(_ passage: String) async throws -> PassageValues {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else {
            throw OrigamiLLMError.appleUnavailable
        }
        // A fresh session per chunk: single-turn, so earlier chunks never
        // crowd the context window.
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: "Extract the entities and concepts in this passage:\n\n\(passage)",
            generating: PassageExtraction.self)
        let content = response.content
        return PassageValues(concepts: content.concepts, keywords: content.keywords,
                             people: content.people, places: content.places,
                             technologies: content.technologies,
                             scientificTerms: content.scientificTerms)
        #else
        throw OrigamiLLMError.appleUnavailable
        #endif
    }

    /// The two FoundationModels error enums both name these conditions;
    /// classify against both, and match endpoint overflows by message.
    static func isContextOverflow(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if let generation = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generation { return true }
        if #available(macOS 27.0, *), let model = error as? LanguageModelError,
           case .contextSizeExceeded = model { return true }
        #endif
        return "\(error)".localizedCaseInsensitiveContains("context")
    }

    static func isGuardrail(_ error: Error) -> Bool {
        #if canImport(FoundationModels)
        if let generation = error as? LanguageModelSession.GenerationError,
           case .guardrailViolation = generation { return true }
        if #available(macOS 27.0, *), let model = error as? LanguageModelError,
           case .guardrailViolation = model { return true }
        #endif
        return false
    }
}

/// The plain values either path produces — guided generation's typed
/// content, or an endpoint's JSON.
nonisolated struct PassageValues {
    var concepts: [String] = []
    var keywords: [String] = []
    var people: [String] = []
    var places: [String] = []
    var technologies: [String] = []
    var scientificTerms: [String] = []

    init(concepts: [String] = [], keywords: [String] = [], people: [String] = [],
         places: [String] = [], technologies: [String] = [],
         scientificTerms: [String] = []) {
        self.concepts = concepts
        self.keywords = keywords
        self.people = people
        self.places = places
        self.technologies = technologies
        self.scientificTerms = scientificTerms
    }

    /// Reads the first JSON object out of a possibly chatty reply —
    /// local models often wrap JSON in prose or code fences.
    init?(lenientJSON text: String) {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        let body = String(text[start...end])
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func strings(_ key: String) -> [String] {
            (object[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        self.init(concepts: strings("concepts"), keywords: strings("keywords"),
                  people: strings("people"), places: strings("places"),
                  technologies: strings("technologies"),
                  scientificTerms: strings("scientificTerms"))
    }
}
#endif
