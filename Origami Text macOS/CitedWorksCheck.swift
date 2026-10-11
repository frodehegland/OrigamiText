import Foundation
import Observation

/// Settings ▸ References ▸ Check Library Now: every work the library
/// cites, looked up once and written to the community folder as
/// `origami-cited-works.json` — so the headset (and any other Mac) knows
/// a cited work's standing and its context without asking a service
/// itself. The Mac builds the record; every device reads it.
///
/// Polite by construction: one work at a time, a pause between works,
/// a month's rest for a work already checked, and the record published
/// as it grows, so a long pass shares what it has found so far.
@MainActor @Observable
final class CitedWorksCheck {
    static let shared = CitedWorksCheck()

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    /// How many works the record holds, after the last pass or read.
    private(set) var recorded = 0
    private(set) var lastChecked: Date? =
        UserDefaults.standard.object(forKey: lastCheckedKey) as? Date

    private static let lastCheckedKey = "citedWorksLastChecked"
    /// A work checked this recently is left alone.
    private static let restDays = 30.0
    /// The pause between works — each work asks several services at once.
    private static let pause = Duration.milliseconds(300)
    /// How often a running pass publishes what it has.
    private static let publishEvery = 40

    private var task: Task<Void, Never>?

    /// One work to check: its key in the record, and its reference.
    private struct Work {
        let key: String
        let record: BibTeXRecord
        let doi: String?
        let title: String
        let year: Int?
        /// The library papers citing it.
        var citedBy: [String]
    }

    /// Begins a pass over every reference in the documents. `force`
    /// checks works already checked within the month as well.
    /// `docs` by their library id — the master list records which
    /// papers cite each work.
    func start(docs: [String: LiquidDoc], folder: URL?, force: Bool = false) {
        guard !isRunning, let folder else { return }
        isRunning = true
        done = 0
        task = Task { [weak self] in
            await self?.run(docs: docs, folder: folder, force: force)
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// The record as the folder holds it, for the status line.
    func refreshCount(folder: URL?) async {
        await ReferenceStatus.adoptShared(from: folder)
        recorded = ReferenceStatus.shared.count
    }

    private func run(docs: [String: LiquidDoc], folder: URL, force: Bool) async {
        defer { isRunning = false }
        // The databases first: their notices go into every record.
        await ReferenceStatus.refreshIndexIfStale()
        await ReferenceStatus.refreshReplicationsIfStale()
        await ReferenceStatus.adoptShared(from: folder)
        var works = ReferenceStatus.shared

        let all = Self.works(in: docs)
        // Who cites each work, written into every record — the checked
        // and the resting alike.
        for work in all {
            works[work.key]?.citedBy = work.citedBy
        }
        let pending = all.filter { work in
            guard !force, let held = works[work.key] else { return true }
            return Date.now.timeIntervalSince(held.checked) > Self.restDays * 86_400
        }
        total = pending.count
        for work in pending {
            if Task.isCancelled { break }
            var (record, foundDOI) = await check(work)
            record.citedBy = work.citedBy
            works[work.key] = record
            // A work found by its title is also known by its DOI, so a
            // reference elsewhere that carries the DOI finds it too.
            if let foundDOI, foundDOI != work.key {
                works[foundDOI] = record
            }
            done += 1
            if done.isMultiple(of: Self.publishEvery) {
                await ReferenceStatus.publish(works, to: folder)
                ReferenceStatus.adoptOwn(works)
            }
            try? await Task.sleep(for: Self.pause)
        }
        await ReferenceStatus.publish(works, to: folder)
        ReferenceStatus.adoptOwn(works)
        recorded = works.count
        lastChecked = .now
        UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
    }

    /// One work: its DOI found when it has none, its live answers, its
    /// abstract — then folded into a record.
    private func check(_ work: Work) async -> (ReferenceStatus.CitedWork, String?) {
        var doi = work.doi
        var enrichment = CitationLookup.cached(for: work.record)
        // A reference without a DOI is found by its title first.
        if doi == nil, CitationLookup.isEnabled {
            enrichment = await CitationLookup.enrich(work.record)
            doi = ReferenceStatus.cleanDOI(enrichment?.doi)
        }
        if let doi, ReferenceStatus.needsLive(doi: doi) {
            await ReferenceStatus.checkLive(doi: doi)
        }
        let bibAbstract = work.record.fields["abstract"]
            .map { BibTeXParser.displayText($0) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // No abstract yet from the reference or OpenAlex: the lookup's
        // other providers.
        if bibAbstract == nil, ReferenceStatus.cachedLive(doi: doi)?.abstract == nil,
           enrichment == nil, CitationLookup.isEnabled {
            enrichment = await CitationLookup.enrich(work.record)
        }
        let abstract = bibAbstract ?? enrichment?.abstract
        let record = ReferenceStatus.record(
            doi: doi, title: work.title, year: work.year,
            abstract: abstract,
            abstractSource: bibAbstract != nil ? "the reference" : enrichment?.source,
            summary: enrichment?.tldr, venue: enrichment?.venue)
        return (record, doi)
    }

    /// Every distinct work the documents cite.
    private static func works(in docs: [String: LiquidDoc]) -> [Work] {
        var index: [String: Int] = [:]
        var out: [Work] = []
        for (paperID, doc) in docs.sorted(by: { $0.key < $1.key }) {
            for reference in doc.references {
                guard let record = BibTeXRecord.records(in: reference.bibtex).first else { continue }
                let title = record.title.isEmpty ? (reference.citedAs ?? "") : record.title
                let doi = ReferenceStatus.cleanDOI(record.fields["doi"])
                guard let key = ReferenceStatus.sharedKey(doi: doi, title: title) else { continue }
                if let at = index[key] {
                    if !out[at].citedBy.contains(paperID) { out[at].citedBy.append(paperID) }
                    continue
                }
                index[key] = out.count
                out.append(Work(key: key, record: record, doi: doi, title: title,
                                year: Int(record.year.filter(\.isNumber).prefix(4)),
                                citedBy: [paperID]))
            }
        }
        return out
    }
}
