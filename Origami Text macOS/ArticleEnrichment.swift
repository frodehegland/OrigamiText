#if os(macOS)
import CryptoKit
import Foundation
import Observation
import SwiftUI

/// Build Article Metadata (a library row's menu, any bound volume): every
/// article of the chosen volumes given an abstract, keywords and the
/// reader's Defined Concepts its pages use — so the headset's cards carry
/// them and its assistant can say which articles are alike.
///
/// Each value comes from the best source there is, and says which:
/// 1. the book's own binding (nothing is written then);
/// 2. an abstract the article prints under its own "Abstract";
/// 3. the volume's summaries page (FoT Vol 5's "Article Summaries");
/// 4. the reader's model, through OrigamiLLM — an abstract and keywords
///    at once, marked "ai · <model>";
/// 5. for keywords only, when no model answers: the words the article
///    uses far more than the rest of the run's articles do.
/// Defined Concepts are checked on every pass, so a concept defined since
/// the last one is found. An article already done keeps what it has
/// unless its text changed or Redo AI Abstracts is on. The record is
/// kept beside the shelf and published to the community folder as it
/// grows (`ArticleMetadata`).
@MainActor @Observable
final class ArticleEnrichment {
    static let shared = ArticleEnrichment()

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var current: String?
    /// What the pass did, newest last — failures included.
    private(set) var log: [String] = []
    /// Book folder → work id → what was learned.
    private(set) var store: [String: [String: ArticleMetadata.Entry]] = ArticleEnrichment.loadLocal()
    /// The volumes the window has ticked, by book folder.
    var selection: Set<String> = []
    /// Make a new AI abstract even where an earlier pass made one.
    var redoAI = false

    private var task: Task<Void, Never>?
    private static let publishEvery = 8

    /// The Mac's own copy, beside the shelf.
    static var localURL: URL {
        AppModel.annotationsRootURL.deletingLastPathComponent()
            .appendingPathComponent(ArticleMetadata.fileName)
    }

    private static func loadLocal() -> [String: [String: ArticleMetadata.Entry]] {
        ArticleMetadata.read(localURL)?.volumes ?? [:]
    }

    /// Ticks a volume and every other volume of its series.
    func select(seriesOf record: EPUBRecord, in model: AppModel) {
        let seriesID = model.boundVolume(for: record)?.series?.id
        selection = Set(model.epubRecords.filter { other in
            guard let bound = model.boundVolume(for: other) else { return false }
            return other.folder == record.folder || (seriesID != nil && bound.series?.id == seriesID)
        }.map(\.folder))
    }

    func start(model: AppModel) {
        start(volumes: model.epubRecords.filter { selection.contains($0.folder) }, model: model)
    }

    /// The pass over the given volumes. In the background (Library
    /// Upkeep) it runs at background priority and waits, before each
    /// article, until the Mac has been left alone (`BackgroundPace`).
    func start(volumes: [EPUBRecord], model: AppModel, background: Bool = false) {
        guard !isRunning, !volumes.isEmpty else { return }
        isRunning = true
        self.background = background
        done = 0
        log = background ? ["Started by Library Upkeep, at low priority."] : []
        task = Task(priority: background ? .background : nil) { [weak self] in
            await self?.run(volumes: volumes, model: model)
        }
    }

    /// Run by Library Upkeep: low priority, and paced to the reader.
    private var background = false

    func stop() { task?.cancel() }

    /// How much a volume has: articles with an abstract, keywords, concepts.
    func coverage(of record: EPUBRecord, in model: AppModel) -> (works: Int, abstracts: Int, keywords: Int, concepts: Int) {
        guard let bound = model.boundVolume(for: record) else { return (0, 0, 0, 0) }
        let entries = store[record.folder] ?? [:]
        var abstracts = 0, keywords = 0, concepts = 0
        for work in bound.works {
            let entry = entries[work.id]
            if !(work.abstract ?? "").isEmpty || !(entry?.abstract ?? "").isEmpty { abstracts += 1 }
            if !work.keywords.isEmpty || !(entry?.keywords ?? []).isEmpty { keywords += 1 }
            if !(entry?.concepts ?? []).isEmpty { concepts += 1 }
        }
        return (bound.works.count, abstracts, keywords, concepts)
    }

    // MARK: The pass

    /// One article, read and ready.
    private struct Work: Sendable {
        let folder: String
        let volumeTitle: String
        let year: String?
        let article: BoundVolume.Article
        let text: String
        let hash: String
        let printed: String?
        let summary: (abstract: String, keywords: [String], generated: Bool)?
    }

    private func run(volumes: [EPUBRecord], model: AppModel) async {
        defer { isRunning = false; current = nil }
        let sources = volumes.map { record in
            (record, model.unpackedFolder(for: record))
        }
        // Read every article's text off the main actor: the book's own
        // binding, not the enriched one, so the book's values are known.
        current = "Reading the volumes…"
        let works: [Work] = await Task.detached(priority: background ? .background : .userInitiated) {
            var out: [Work] = []
            for (record, folder) in sources {
                guard let bound = BoundVolume.read(inUnpackedFolder: folder) else { continue }
                let summaries = bound.summaries(inUnpackedFolder: folder)
                for article in bound.works {
                    let blocks = bound.blocks(of: article, inUnpackedFolder: folder)
                    let text = blocks.joined(separator: "\n\n")
                    let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
                    out.append(Work(folder: record.folder, volumeTitle: record.title,
                                    year: record.dateISO.map { String($0.prefix(4)) },
                                    article: article, text: text, hash: hash,
                                    printed: BoundVolume.printedAbstract(in: blocks),
                                    summary: summaries[article.id]))
                }
            }
            return out
        }.value
        total = works.count
        say("\(works.count) articles in \(volumes.count) volume\(volumes.count == 1 ? "" : "s").")

        // The fallback keywords: what each article says more than the rest.
        let terms = await Task.detached(priority: background ? .background : .utility) {
            Self.distinctiveTerms(works.map { ($0.article.title + ". " + $0.text, $0.article.authors) })
        }.value

        let concepts = model.conceptLibrary.liveConcepts.map {
            (id: $0.id, name: $0.term, names: [$0.term] + $0.alternativeNames)
        }
        say(concepts.isEmpty
            ? "No Defined Concepts in your library yet — none to look for."
            : "Looking for \(concepts.count) Defined Concepts.")
        let llm = OrigamiLLM.shared
        if !llm.canRespond { say("No model answers: abstracts the books lack will wait; keywords come from the articles' own terms.") }

        var sincePublish = 0
        for (index, work) in works.enumerated() {
            if background { await BackgroundPace.waitForQuiet() }
            if Task.isCancelled { say("Stopped."); break }
            current = work.article.title
            let prior = store[work.folder]?[work.article.id]
            let unchanged = prior?.textHash == work.hash
            var entry = prior ?? ArticleMetadata.Entry(title: work.article.title, textHash: work.hash, made: .now)
            entry.title = work.article.title
            entry.textHash = work.hash
            entry.note = nil
            let words = work.text.split(whereSeparator: \.isWhitespace).count

            // The abstract.
            let bookHas = !(work.article.abstract ?? "").isEmpty
            if bookHas {
                entry.abstract = nil
                entry.abstractSource = "book"
            } else if let printed = work.printed {
                entry.abstract = printed
                entry.abstractSource = "book"
            } else if let summary = work.summary {
                entry.abstract = summary.abstract
                entry.abstractSource = summary.generated ? "summaries · Gen:AI" : "summaries"
            } else if !(unchanged && !redoAI && (entry.abstractSource ?? "").hasPrefix("ai")
                        && !(entry.abstract ?? "").isEmpty) {
                entry.abstract = nil
                entry.abstractSource = nil
            }
            // The keywords.
            if !work.article.keywords.isEmpty {
                entry.keywords = []
                entry.keywordsSource = "book"
            } else if let summary = work.summary, !summary.keywords.isEmpty {
                entry.keywords = summary.keywords
                entry.keywordsSource = "summaries"
            } else if !(unchanged && !redoAI && (entry.keywordsSource ?? "").hasPrefix("ai") && !entry.keywords.isEmpty) {
                entry.keywords = []
                entry.keywordsSource = nil
            }

            // The model, for whatever is still missing.
            let needsAbstract = entry.abstractSource == nil
            let needsKeywords = entry.keywordsSource == nil
            if (needsAbstract || needsKeywords), words < 40 {
                entry.note = "Too little text to summarise (\(words) words) — pictures, or a poem."
            } else if (needsAbstract || needsKeywords), llm.canRespond {
                do {
                    let made = try await ask(llm, about: work, abstract: needsAbstract)
                    if needsAbstract, let abstract = made.abstract {
                        entry.abstract = abstract
                        entry.abstractSource = "ai · " + made.model
                    }
                    if needsKeywords, !made.keywords.isEmpty {
                        entry.keywords = made.keywords
                        entry.keywordsSource = "ai · " + made.model
                    }
                    if needsAbstract, made.abstract == nil { entry.note = "The model's answer held no abstract." }
                } catch {
                    // Reported and left to be asked again — never kept as an answer.
                    entry.note = ReadingAI.reason(error)
                    say("\(work.article.title): \(ReadingAI.reason(error))")
                }
            }
            if entry.keywordsSource == nil, let own = terms[index], !own.isEmpty {
                entry.keywords = own
                entry.keywordsSource = "terms"
            }

            // The reader's Defined Concepts, whole words, any of their names.
            let text = work.article.title + "\n" + work.text
            entry.concepts = concepts.filter { concept in
                concept.names.contains { !$0.isEmpty && ConceptTerm.text(text, contains: $0) }
            }.map { ArticleMetadata.Concept(id: $0.id, name: $0.name) }

            entry.made = .now
            store[work.folder, default: [:]][work.article.id] = entry
            done = index + 1
            sincePublish += 1
            if sincePublish >= Self.publishEvery {
                sincePublish = 0
                await publish(model: model)
            }
        }
        await publish(model: model)
        let made = works.filter { (store[$0.folder]?[$0.article.id]?.abstractSource ?? "").hasPrefix("ai") }.count
        let unfinished = works.filter { store[$0.folder]?[$0.article.id]?.note != nil }.count
        say("Done: \(done) of \(total) read; \(made) AI abstracts held; \(unfinished) need another try.")
    }

    /// The model's abstract and keywords for one article.
    private func ask(_ llm: OrigamiLLM, about work: Work, abstract wanted: Bool)
        async throws -> (abstract: String?, keywords: [String], model: String) {
        let byline = work.article.byline.isEmpty ? "" : " by \(work.article.byline)"
        let year = work.year.map { ", \($0)" } ?? ""
        let instructions = """
            You write catalogue abstracts and keywords for the articles of an anthology. \
            Write plain English in the third person, present tense ("The author argues…"). \
            Say what the article itself argues, shows or proposes; do not praise it. \
            No preamble, no headings, nothing but the reply asked for.
            """
        let form = wanted
            ? "Abstract: <one paragraph of 60 to 120 words>\nKeywords: <4 to 6 keywords or short phrases, comma separated>"
            : "Keywords: <4 to 6 keywords or short phrases, comma separated>"
        let prompt = """
            Article: "\(work.article.title)"\(byline), in \(work.volumeTitle)\(year).

            Text:
            \(String(work.text.prefix(7000)))

            Reply in exactly this form:
            \(form)
            """
        let reply = try await llm.respond(instructions: instructions, to: prompt, transformingContent: true)
        let parsed = Self.parse(reply.text, wantsAbstract: wanted)
        return (parsed.abstract, parsed.keywords, reply.modelName)
    }

    /// "Abstract: … / Keywords: …" read back; a reply without the labels
    /// is taken whole as the abstract when it is long enough to be one.
    nonisolated static func parse(_ reply: String, wantsAbstract: Bool) -> (abstract: String?, keywords: [String]) {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var keywords: [String] = []
        if let range = text.range(of: #"(?im)^\**\s*keywords\s*\**\s*:"#, options: .regularExpression) {
            let line = text[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
            keywords = line.split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters)) }
                .filter { !$0.isEmpty && $0.split(separator: " ").count <= 5 }
            text = String(text[..<range.lowerBound])
        }
        guard wantsAbstract else { return (nil, Array(keywords.prefix(6))) }
        if let range = text.range(of: #"(?i)\**\s*abstract\s*\**\s*:"#, options: .regularExpression) {
            text = String(text[range.upperBound...])
        }
        let abstract = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (abstract.split(separator: " ").count >= 25 ? abstract : nil, Array(keywords.prefix(6)))
    }

    /// For each article, the six words it uses most that few others do —
    /// its contributors' names left out.
    nonisolated static func distinctiveTerms(_ articles: [(text: String, authors: [String])]) -> [Int: [String]] {
        let counts = articles.map { SeriesIndex.nounCounts($0.text) }
        var spread: [String: Int] = [:]
        for terms in counts { for term in terms.keys { spread[term, default: 0] += 1 } }
        let names = Set(articles.flatMap(\.authors)
            .flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
        let ceiling = max(2, articles.count / 5)
        var out: [Int: [String]] = [:]
        for (index, terms) in counts.enumerated() {
            let scored = terms.compactMap { term, count -> (String, Double)? in
                let df = spread[term] ?? 1
                guard count >= 2, df >= 2, df <= ceiling, !names.contains(term) else { return nil }
                let rarity = Foundation.log(Double(articles.count) / Double(df))
                return (term, Double(count) * rarity)
            }
            let ranked = scored.sorted { (a: (String, Double), b: (String, Double)) -> Bool in
                a.1 != b.1 ? a.1 > b.1 : a.0 < b.0
            }
            out[index] = ranked.prefix(6).map(\.0)
        }
        return out
    }

    /// The record, kept here and published to the community folder.
    private func publish(model: AppModel) async {
        let file = ArticleMetadata.File(modified: .now, volumes: store)
        let local = Self.localURL
        let community = model.index.folderURL
        await Task.detached(priority: .utility) {
            ArticleMetadata.write(file, to: local)
            if let community { ArticleMetadata.publish(file, to: community) }
        }.value
    }

    private func say(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

/// The Build Article Metadata window: the bound volumes by series, the
/// pass's controls, and what each article now carries.
struct ArticleEnrichmentView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewFolder: String?
    private var enrichment: ArticleEnrichment { ArticleEnrichment.shared }

    /// The bound volumes, grouped by series (a volume alone is its own).
    private var groups: [(name: String, volumes: [EPUBRecord])] {
        var order: [String] = []
        var byKey: [String: (name: String, volumes: [(Int?, EPUBRecord)])] = [:]
        for record in model.epubRecords {
            guard let bound = model.boundVolume(for: record) else { continue }
            let key = bound.series?.id ?? record.folder
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = (bound.series?.name ?? record.title, [])
            }
            byKey[key]?.volumes.append((bound.series?.volume, record))
        }
        return order.compactMap { byKey[$0] }.map { group in
            (group.name, group.volumes.sorted { ($0.0 ?? Int.max, $0.1.title) < ($1.0 ?? Int.max, $1.1.title) }.map(\.1))
        }
    }

    var body: some View {
        @Bindable var enrichment = enrichment
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Gives every article of the ticked volumes an abstract, keywords and the Defined Concepts its pages use. The book's own come first, then a summaries page, then your model. Nothing is written into the books. The record goes to the community folder, where the headset reads it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                List {
                    ForEach(groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.volumes) { record in
                                volumeRow(record)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
                Toggle("Redo AI abstracts and keywords made by an earlier pass", isOn: $enrichment.redoAI)
                HStack {
                    Button(enrichment.store.isEmpty ? "Build" : "Build Again") {
                        enrichment.start(model: model)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(enrichment.isRunning || enrichment.selection.isEmpty)
                    Button("Stop") { enrichment.stop() }
                        .disabled(!enrichment.isRunning)
                    Spacer()
                    Button("Show Record in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ArticleEnrichment.localURL])
                    }
                }
                Text("Model: \(OrigamiLLM.shared.selectedDisplayName)\(OrigamiLLM.shared.canRespond ? "" : " — not answering")  ·  Defined Concepts: \(model.conceptLibrary.liveConcepts.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if enrichment.isRunning || enrichment.total > 0 {
                    ProgressView(value: Double(enrichment.done), total: Double(max(enrichment.total, 1))) {
                        Text(enrichment.current ?? "\(enrichment.done) of \(enrichment.total)")
                            .lineLimit(1)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(enrichment.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 70, maxHeight: 140)
            }
            .padding()
            .frame(minWidth: 380, idealWidth: 420)

            review
                .frame(minWidth: 380)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private func volumeRow(_ record: EPUBRecord) -> some View {
        let have = enrichment.coverage(of: record, in: model)
        return HStack {
            Toggle(isOn: Binding(
                get: { enrichment.selection.contains(record.folder) },
                set: { on in
                    if on { enrichment.selection.insert(record.folder) } else { enrichment.selection.remove(record.folder) }
                })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title).lineLimit(1)
                    Text("\(have.works) articles · \(have.abstracts) abstracts · \(have.keywords) keywords · \(have.concepts) with concepts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Review") { reviewFolder = record.folder }
                .buttonStyle(.borderless)
        }
    }

    /// What each article of the reviewed volume carries now, and from where.
    @ViewBuilder private var review: some View {
        if let folder = reviewFolder,
           let record = model.epubRecords.first(where: { $0.folder == folder }),
           let bound = model.boundVolume(for: record) {
            let entries = enrichment.store[folder] ?? [:]
            List {
                Section(record.title) {
                    ForEach(bound.works) { work in
                        let entry = entries[work.id]
                        let abstract = (work.abstract ?? "").isEmpty ? entry?.abstract : work.abstract
                        let keywords = work.keywords.isEmpty ? (entry?.keywords ?? []) : work.keywords
                        VStack(alignment: .leading, spacing: 4) {
                            Text(work.title).font(.headline)
                            if !work.byline.isEmpty {
                                Text(work.byline).font(.caption).foregroundStyle(.secondary)
                            }
                            if let abstract, !abstract.isEmpty {
                                Text(abstract).font(.callout).textSelection(.enabled)
                            }
                            Text("Abstract: \(entry?.abstractSource ?? ((work.abstract ?? "").isEmpty ? "none yet" : "book"))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !keywords.isEmpty {
                                Text("Keywords: " + keywords.joined(separator: ", ")
                                     + " (\(entry?.keywordsSource ?? "book"))")
                                    .font(.caption)
                            }
                            if let concepts = entry?.concepts, !concepts.isEmpty {
                                Text("Defined Concepts: " + concepts.map(\.name).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                            if let note = entry?.note {
                                Text(note).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        } else {
            ContentUnavailableView("Choose Review on a volume", systemImage: "text.magnifyingglass",
                                   description: Text("Each article's abstract, keywords and Defined Concepts, with where each came from."))
        }
    }
}
#endif
