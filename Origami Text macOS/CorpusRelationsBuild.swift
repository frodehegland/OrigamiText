#if os(macOS)
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Build Corpus Relations (a bound volume's row menu): who cites what
/// across a whole series — inside the corpus and out — read from the
/// volumes' own bibliographies, endnotes and bindings, and published
/// beside the EPUBs as the editor's and publisher's metadata
/// (`CorpusRelations`, CORPUS-RELATIONS-PLAN.md). Facts only, for now:
/// the similar and the disagreeing come in a later pass.
@MainActor @Observable
final class CorpusRelationsBuilder {
    static let shared = CorpusRelationsBuilder()

    private(set) var isRunning = false
    private(set) var log: [String] = []
    private(set) var file: CorpusRelations.File? = CorpusRelations.read(CorpusRelationsBuilder.localURL)

    /// The published record's licence: Creative Commons Attribution 4.0.
    nonisolated static let licence = "CC-BY-4.0"

    /// The Mac's own copy, beside the shelf.
    static var localURL: URL {
        AppModel.annotationsRootURL.deletingLastPathComponent()
            .appendingPathComponent(CorpusRelations.fileName)
    }

    /// What a corpus is made of: a series' (or lone volume's) volumes, in
    /// the series' order, or a journal's papers, each read whole.
    typealias Target = (id: String, name: String, volumes: [EPUBRecord], papers: [EPUBRecord])

    /// The corpus a record belongs to: its series (or itself, a lone
    /// volume) when it is bound; else its journal — every paper on the
    /// shelf declaring the same venue that is not itself a volume.
    func corpus(of record: EPUBRecord, in model: AppModel) -> Target {
        let bound = model.boundVolume(for: record)
        guard bound != nil else {
            guard let venue = record.venue else { return (record.folder, record.title, [], [record]) }
            let papers = model.epubRecords.filter {
                $0.venue?.caseInsensitiveCompare(venue) == .orderedSame && model.boundVolume(for: $0) == nil
            }.sorted { ($0.dateISO ?? "", $0.title) < ($1.dateISO ?? "", $1.title) }
            return (CorpusRelations.journalPrefix + venue, venue, [], papers)
        }
        guard let series = bound?.series else { return (record.folder, record.title, [record], []) }
        let volumes = model.epubRecords
            .compactMap { other -> (EPUBRecord, Int?)? in
                guard let theirs = model.boundVolume(for: other)?.series, theirs.id == series.id else { return nil }
                return (other, theirs.volume)
            }
            .sorted { ($0.1 ?? Int.max, $0.0.dateISO ?? "", $0.0.title) < ($1.1 ?? Int.max, $1.0.dateISO ?? "", $1.0.title) }
            .map(\.0)
        return (series.id, series.name.isEmpty ? record.title : series.name, volumes, [])
    }

    /// Run by Library Upkeep: background priority, and paced to the reader.
    private var background = false
    private var workPriority: TaskPriority { background ? .background : .userInitiated }

    /// Every corpus the shelf holds: each series (a lone bound volume is
    /// its own), then each journal of two or more papers, by name.
    func allCorpora(in model: AppModel) -> [Target] {
        var seen = Set<String>()
        let all = model.epubRecords.compactMap { record -> Target? in
            guard model.boundVolume(for: record) != nil || record.venue != nil else { return nil }
            let corpus = corpus(of: record, in: model)
            guard !corpus.volumes.isEmpty || corpus.papers.count >= 2 else { return nil }
            return seen.insert(corpus.id).inserted ? corpus : nil
        }
        return all.filter { $0.papers.isEmpty } + all.filter { !$0.papers.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func build(corpusOf record: EPUBRecord, model: AppModel, background: Bool = false) {
        guard !isRunning else { return }
        let target = corpus(of: record, in: model)
        isRunning = true
        self.background = background
        log = [target.papers.isEmpty
               ? "Reading \(target.volumes.count) volume\(target.volumes.count == 1 ? "" : "s") of \(target.name)…"
               : "Reading \(target.papers.count) papers of \(target.name)…"]
        let sources = target.volumes.compactMap { volume in
            model.boundVolume(for: volume).map {
                CorpusRelations.VolumeSource(folder: volume.folder, unpacked: model.unpackedFolder(for: volume), bound: $0)
            }
        }
        // A journal's papers, from the library's own reading of each: its
        // reference list for the citations; its title, authors, keywords,
        // abstract, body and glossary for the reading.
        let paperDocs: [(record: EPUBRecord, doc: LiquidDoc)] = target.papers.compactMap { record in
            guard let doc = model.index.byID[record.id]?.doc else { return nil }
            return (record, doc)
        }
        if paperDocs.count < target.papers.count {
            log.append("\(target.papers.count - paperDocs.count) papers are not yet read into the library and are left out.")
        }
        let papers = paperDocs.map { record, doc in
            CorpusRelations.PaperSource(folder: record.folder,
                                        title: doc.title.isEmpty ? record.title : doc.title,
                                        authors: doc.authors.isEmpty ? record.authorList : doc.authors,
                                        references: doc.references.map(\.bibtex))
        }
        let paperTexts: [PieceText] = paperDocs.map { record, doc in
            let body = (doc.body ?? []).map(\.text).joined(separator: "\n")
            let title = doc.title.isEmpty ? record.title : doc.title
            return PieceText(
                key: CorpusRelations.pieceKey(folder: record.folder, work: CorpusRelations.wholeWork),
                title: title, authors: doc.authors.isEmpty ? record.authorList : doc.authors,
                keywords: doc.keywords, text: title + "\n" + body,
                embeddingInput: title + "\n" + (doc.abstract ?? "") + "\n" + String(body.prefix(2000)))
        }
        let paperGlossary: [(name: String, definition: String?)] = paperDocs.flatMap { _, doc in
            doc.concepts.map { concept -> (name: String, definition: String?) in
                (concept.name, concept.userDefinition ?? (concept.description.isEmpty ? nil : concept.description))
            }
        }
        let community = model.index.folderURL
        let previous = file
        let local = Self.localURL
        let priority = workPriority
        if background { log.append("Started by Library Upkeep, at low priority.") }
        Task(priority: background ? .background : nil) {
            if background { await BackgroundPace.waitForQuiet() }
            // The facts first: who cites what.
            var corpus = await Task.detached(priority: priority) {
                CorpusRelations.build(name: target.name, volumes: sources, papers: papers,
                                      known: Self.masterList(in: community))
            }.value
            log += corpus.findings
            // Then the reading: themes, terms, people, meaning.
            await read(into: &corpus, sources: sources, papers: paperTexts, paperGlossary: paperGlossary)
            let built = await Task.detached(priority: priority) { [corpus] () -> CorpusRelations.File in
                var file = previous ?? CorpusRelations.File(modified: .now, corpora: [:])
                file.modified = .now
                file.corpora[target.id] = corpus
                // The volumes' own compiler stands as the publisher.
                if let first = sources.first, let editor = Self.editor(inUnpackedFolder: first.unpacked) {
                    file.publisher = CorpusRelations.Publisher(name: editor, role: "editor and publisher")
                }
                // Free to reuse with credit to the editor and publisher
                // (Frode's choice, 1 Nov 2026), as its SPDX identifier.
                file.licence = Self.licence
                CorpusRelations.write(file, to: local)
                if let community { CorpusRelations.publish(file, to: community) }
                return file
            }.value
            file = built
            log.append(community == nil
                       ? "Kept beside the shelf; no community folder to publish to."
                       : "Published to the community folder, where the headset reads it.")
            isRunning = false
        }
    }

    // MARK: The reading

    /// One piece as the reading takes it.
    private struct PieceText: Sendable {
        let key: String
        let title: String
        let authors: [String]
        let keywords: [String]
        /// The whole text, for terms and people.
        let text: String
        /// What the embedding reads: the title, the abstract and the
        /// opening 2000 characters — enough to say what a piece is about,
        /// and short enough to embed the corpus in minutes (a model's
        /// time grows steeply with length: 1.3 s at 3000 characters, 7 s
        /// at 6000, on qwen3-embedding:8b).
        let embeddingInput: String
    }

    /// Themes (keywords merged by meaning), the books' glossary as the
    /// pieces use it, the people they mention, and — when the embedding
    /// model stands on Ollama — each piece's nearest, its group and its
    /// place by meaning. Without the model the rest is still read, and
    /// themes merge by spelling alone.
    private func read(into corpus: inout CorpusRelations.Corpus, sources: [CorpusRelations.VolumeSource],
                      papers: [PieceText] = [], paperGlossary: [(name: String, definition: String?)] = []) async {
        let metadata = ArticleMetadata.read(ArticleEnrichment.localURL)?.volumes ?? [:]
        let citedAuthors = Set(corpus.works.values.flatMap(\.authors))
        log.append("Reading the pieces' text, keywords and the books' glossaries…")
        let gathered = await Task.detached(priority: workPriority) {
            Self.gather(sources: sources, metadata: metadata)
        }.value
        let pieces = gathered.pieces + papers
        let contributors = Set(pieces.flatMap(\.authors))
        let texts = Dictionary(uniqueKeysWithValues: pieces.map { ($0.key, $0.text) })
        let keywords = Dictionary(uniqueKeysWithValues: pieces.map { ($0.key, $0.keywords) })
        let authorsOf = Dictionary(uniqueKeysWithValues: pieces.map { ($0.key, $0.authors) })

        // People, from the names the corpus knows and Apple's tagger.
        if background { await BackgroundPace.waitForQuiet() }
        let people = await Task.detached(priority: workPriority) {
            CorpusRelations.peopleMentioned(texts: texts, contributors: contributors,
                                            known: citedAuthors, authorsOf: authorsOf)
        }.value
        corpus.people = people
        log.append("People: \(people.count) named in two or more pieces (\(people.filter(\.isContributor).count) of them contributors).")

        // The glossary, its people left to People.
        let personNames = contributors.union(people.map(\.name))
        let glossary = gathered.glossary + paperGlossary
        let terms = await Task.detached(priority: workPriority) {
            CorpusRelations.glossaryTerms(glossary, texts: texts, people: personNames)
        }.value
        corpus.terms = terms
        log.append("Glossary: \(terms.count) of the books' \(Set(glossary.map { $0.name.lowercased() }).count) terms kept, used in \(Set(terms.flatMap(\.pieces)).count) pieces.")

        // Meaning, when the embedding model answers.
        let llm = OrigamiLLM.shared
        guard await llm.hasEmbeddingModel() else {
            corpus.themes = CorpusRelations.keywordThemes(keywords, vectors: nil)
            log.append("Themes: \(corpus.themes?.count ?? 0), merged by spelling only — the embedding model \(llm.activeEmbeddingModel) is not available (Settings ▸ AI ▸ AI on This Mac). Similar, groups and the meaning map wait for it.")
            return
        }
        let model = llm.activeEmbeddingModel
        var cache = Self.loadVectorCache(model: model)
        do {
            let distinct = Array(Set(keywords.values.flatMap { $0 }.map(CorpusRelations.normalizedKeyword)))
                .filter { !$0.isEmpty }.sorted()
            log.append("Embedding \(distinct.count) keywords with \(model)…")
            let keywordVectors = try await embed(distinct, cache: &cache)
            corpus.themes = CorpusRelations.keywordThemes(keywords, vectors: keywordVectors, threshold: 0.85)
            log.append("Themes: \(corpus.themes?.count ?? 0), keywords merged by meaning, in \(Set(corpus.themes?.flatMap(\.pieces) ?? []).count) pieces.")

            log.append("Embedding \(pieces.count) pieces (title, abstract, opening) — some minutes the first time…")
            let inputs = pieces.map(\.embeddingInput)
            let byInput = try await embed(inputs, cache: &cache)
            var vectors: [String: [Float]] = [:]
            for piece in pieces { vectors[piece.key] = byInput[piece.embeddingInput] }
            Self.saveVectorCache(cache, model: model)
            let themes = corpus.themes ?? []
            let mapped = await Task.detached(priority: workPriority) {
                CorpusRelations.meaningMap(vectors: vectors, model: model, themes: themes)
            }.value
            corpus.meaning = mapped.meaning
            corpus.similar = mapped.similar
            log.append("Meaning: \(mapped.meaning.groups.count) groups — " + mapped.meaning.groups.map { "\($0.label) (\($0.pieces.count))" }.joined(separator: ", ") + ".")
        } catch {
            Self.saveVectorCache(cache, model: model)
            if corpus.themes == nil { corpus.themes = CorpusRelations.keywordThemes(keywords, vectors: nil) }
            log.append("Meaning stopped: \(error.localizedDescription) What was embedded is kept for next time.")
        }
    }

    /// Texts as vectors, by text: the cached first, the rest asked of the
    /// model in batches of 8, reporting as it goes.
    private func embed(_ texts: [String], cache: inout [String: [Float]]) async throws -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        var missing: [String] = []
        for text in Set(texts) {
            if let known = cache[Self.cacheKey(text)] { out[text] = known } else { missing.append(text) }
        }
        var done = 0
        for start in stride(from: 0, to: missing.count, by: 8) {
            if background { await BackgroundPace.waitForQuiet() }
            try Task.checkCancellation()
            let slice = Array(missing[start..<min(start + 8, missing.count)])
            let vectors = try await OrigamiLLM.shared.embed(slice).vectors
            for (text, vector) in zip(slice, vectors) {
                out[text] = vector
                cache[Self.cacheKey(text)] = vector
            }
            done += slice.count
            if missing.count > 40, done % 80 < 8 || done == missing.count {
                log.append("   \(done) of \(missing.count)")
            }
        }
        return out
    }

    nonisolated private static func gather(sources: [CorpusRelations.VolumeSource],
                                           metadata: [String: [String: ArticleMetadata.Entry]])
        -> (pieces: [PieceText], glossary: [(name: String, definition: String?)]) {
        var pieces: [PieceText] = []
        var glossary: [(name: String, definition: String?)] = []
        for source in sources {
            let entries = metadata[source.folder] ?? [:]
            for article in source.bound.articles where article.role == .work {
                let body = source.bound.blocks(of: article, inUnpackedFolder: source.unpacked).joined(separator: "\n")
                let entry = entries[article.id]
                let abstract = article.abstract ?? entry?.abstract ?? ""
                pieces.append(PieceText(
                    key: CorpusRelations.pieceKey(folder: source.folder, work: article.id),
                    title: article.title, authors: article.authors,
                    keywords: article.keywords + (entry?.keywords ?? []),
                    text: article.title + "\n" + body,
                    embeddingInput: article.title + "\n" + abstract + "\n" + String(body.prefix(2000))))
            }
            if let data = OrigamiEPUBImporter.recordData(inUnpackedFolder: source.unpacked,
                                                         properties: "origami:visual-meta", fileName: "visual-meta.json"),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for concept in root["concepts"] as? [[String: Any]] ?? [] {
                    if let name = concept["name"] as? String {
                        glossary.append((name, concept["definition"] as? String))
                    }
                }
            }
        }
        return (pieces, glossary)
    }

    // MARK: The vectors, kept on this Mac

    /// Each embedded text's vector, by a hash of the text, per model —
    /// so a rebuild embeds only what changed. Kept in Caches: the
    /// published record carries the results, never the vectors.
    nonisolated private static func vectorCacheURL(model: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safe = model.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return caches.appendingPathComponent("CorpusVectors", isDirectory: true)
            .appendingPathComponent(safe + ".json")
    }

    nonisolated private static func cacheKey(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func loadVectorCache(model: String) -> [String: [Float]] {
        guard let data = try? Data(contentsOf: vectorCacheURL(model: model)),
              let stored = try? JSONDecoder().decode([String: Data].self, from: data) else { return [:] }
        return stored.mapValues { bytes in
            bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    nonisolated private static func saveVectorCache(_ cache: [String: [Float]], model: String) {
        let stored = cache.mapValues { vector in vector.withUnsafeBufferPointer { Data(buffer: $0) } }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let url = vectorCacheURL(model: model)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The Mac's master list of cited works (origami-cited-works.json),
    /// by its key — each work's registry facts.
    nonisolated private static func masterList(in community: URL?) -> [String: ReferenceStatus.CitedWork] {
        guard let community else { return [:] }
        let scoped = community.startAccessingSecurityScopedResource()
        defer { if scoped { community.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: community.appendingPathComponent(ReferenceStatus.sharedFileName))
        else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ReferenceStatus.CitedWorks.self, from: data))?.works ?? [:]
    }

    /// The binding's editor ("compilers", role "editor").
    nonisolated private static func editor(inUnpackedFolder folder: URL) -> String? {
        guard let data = OrigamiEPUBImporter.recordData(
                inUnpackedFolder: folder, properties: "origami:visual-meta", fileName: "visual-meta.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let binding = (root["document"] as? [String: Any])?["binding"] as? [String: Any],
              let compilers = binding["compilers"] as? [[String: Any]]
        else { return nil }
        let editor = compilers.first { ($0["role"] as? String) == "editor" } ?? compilers.first
        return editor?["name"] as? String
    }
}

/// The Build Corpus Relations window: each series, its Build button, and
/// what the last pass found — the findings about the books themselves
/// and the works the corpus cites most.
struct CorpusRelationsView: View {
    @Environment(AppModel.self) private var model
    private var builder: CorpusRelationsBuilder { CorpusRelationsBuilder.shared }

    /// One row per series (a lone bound volume is its own), then one per
    /// journal of two or more papers.
    private var corpora: [CorpusRelationsBuilder.Target] { builder.allCorpora(in: model) }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Traces who cites what across a whole series or journal, inside it and out, from the volumes' own bibliographies, endnotes and bindings, or each paper's own reference list — then reads the pieces: their keywords merged into themes, the books' glossary as the pieces use it, the people they mention, and, with the embedding model (Settings ▸ AI), what each piece is near in meaning. The record is published beside the books as your own metadata; the headset builds its Shapes from it. Nothing is written into the books.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List(corpora, id: \.id) { corpus in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(corpus.name).lineLimit(1)
                            let built = builder.file?.corpora[corpus.id]
                            Text((corpus.papers.isEmpty
                                  ? "\(corpus.volumes.count) volume\(corpus.volumes.count == 1 ? "" : "s")"
                                  : "\(corpus.papers.count) papers")
                                 + (built.map { " · \($0.citations.count) citations of \($0.works.count) works" } ?? " · not built"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(builder.file?.corpora[corpus.id] == nil ? "Build" : "Build Again") {
                            if let first = corpus.volumes.first ?? corpus.papers.first {
                                builder.build(corpusOf: first, model: model)
                            }
                        }
                        .disabled(builder.isRunning)
                    }
                }
                .frame(minHeight: 160)
                HStack {
                    if builder.isRunning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Show Record in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([CorpusRelationsBuilder.localURL])
                    }
                    .disabled(builder.file == nil)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(builder.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120)
            }
            .padding()
            .frame(minWidth: 380, idealWidth: 420)

            canon
                .frame(minWidth: 360)
        }
        .frame(minWidth: 780, minHeight: 520)
    }

    /// The outside works each built corpus cites most widely.
    private var canon: some View {
        List {
            ForEach((builder.file?.corpora ?? [:]).sorted { $0.value.name < $1.value.name }, id: \.key) { _, corpus in
                Section("Most cited by \(corpus.name)") {
                    ForEach(corpus.canon, id: \.self) { key in
                        if let work = corpus.works[key] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(work.title).lineLimit(2)
                                Text([work.authors.prefix(2).joined(separator: ", "),
                                      work.year.map(String.init) ?? "",
                                      "\(work.citedByPieces) article\(work.citedByPieces == 1 ? "" : "s")"
                                        + (work.citedByVolumes > 0 ? " + \(work.citedByVolumes) volume\(work.citedByVolumes == 1 ? "" : "s")" : ""),
                                      work.citedByWorld.map { "cited \($0)× elsewhere" } ?? ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif
