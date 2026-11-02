#if os(macOS)
import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// The library kept up to date without being asked (1 Nov 2026): Frode's
/// wish that the reader reads and thinks, and never manages documents.
///
/// A minute after launch, and every minute after, the upkeep looks for
/// what the shelf lacks — in this order, since each feeds the next:
/// 1. **Article metadata** — a bound volume with articles the record has
///    never read (`ArticleEnrichment`);
/// 2. **Cited works** — documents whose references were never looked up,
///    or a record a month old (`CitedWorksCheck`);
/// 3. **Corpus relations** — a series or journal never built, whose
///    volumes or papers have changed since, never read for themes, or
///    never embedded while the embedding model now stands
///    (`CorpusRelationsBuilder`);
/// 4. **Stances** — citing pairs inside a corpus the stance pass has not
///    read with the current prompt (`StanceFinder`), and on every tick
///    the headset's confirmations and severings folded into the record.
/// It runs one pass at a time, at background priority, and each pass
/// waits between its steps until the Mac has been left alone a while
/// (`BackgroundPace`) — so a reader turning pages never feels it. A pass
/// started by hand runs as before, at full speed, and the upkeep waits
/// for it. What it is doing is one line in Settings ▸ AI, with the switch.
@MainActor @Observable
final class LibraryUpkeep {
    static let shared = LibraryUpkeep()

    /// On by default: the point is that nobody has to remember.
    var isEnabled: Bool = UserDefaults.standard.object(forKey: LibraryUpkeep.enabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    private static let enabledKey = "libraryUpkeepEnabled"

    /// What the upkeep is doing, in a line.
    private(set) var status = "Waiting for the library to open."

    private var task: Task<Void, Never>?

    /// Each job's last try, by job id, with what it tried on — a job that
    /// could not finish (the model away, a paper unread) is tried again a
    /// day later, or at once when its documents change.
    @ObservationIgnored private var attempts: [String: (signature: String, at: Date)] = [:]
    private static let retryAfter: TimeInterval = 86_400

    /// The documents whose references have been looked up, by library id.
    @ObservationIgnored private var lookedUp: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: LibraryUpkeep.lookedUpKey) ?? [])
    private static let lookedUpKey = "libraryUpkeepCitedDocs"

    /// Check Metadata Now is under way: every outstanding job, one after
    /// another, at once — no waiting for the Mac to be idle.
    private(set) var isChecking = false
    @ObservationIgnored private weak var model: AppModel?

    func start(model: AppModel) {
        self.model = model
        guard task == nil else { return }
        task = Task(priority: .background) { [weak self] in
            // The shelf and the index open first; nothing at launch competes.
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                await self?.tick(model: model)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: One look at the library

    private enum Job {
        case articleMetadata([EPUBRecord])
        case citedWorks
        case corpus(EPUBRecord, name: String)
        case stances(corpusID: String, name: String, pairs: Int)
    }

    private var anyPassRunning: Bool {
        ArticleEnrichment.shared.isRunning || CitedWorksCheck.shared.isRunning
            || CorpusRelationsBuilder.shared.isRunning || StanceFinder.shared.isRunning
    }

    private func tick(model: AppModel) async {
        guard !isChecking else { return }
        // The locations this Mac sets, inherited by the other devices —
        // plumbing, so it runs whether or not the upkeep's passes do.
        publishLibrarySettings(model: model)
        guard isEnabled else { status = "Off."; return }
        guard !anyPassRunning else { return }
        guard !model.epubRecords.isEmpty else { status = "No documents yet."; return }
        // The headset's confirmations and severings, folded into the record.
        StanceFinder.foldReviews(model: model)
        guard let (id, signature, job) = await nextJob(model: model) else {
            status = "Up to date — \(model.epubRecords.count) documents."
            return
        }
        attempts[id] = (signature, .now)
        begin(job, model: model, background: true)
        // The pass reports its own progress; the upkeep waits it out.
        while anyPassRunning, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The concept library kept in step with the community folder's, and
    /// the locations written there for every other device to inherit
    /// (2 Nov 2026). Cheap when nothing changed: only differing concepts
    /// are written, and the settings file only when it would change.
    func publishLibrarySettings(model: AppModel) {
        guard let community = model.index.folderURL else { return }
        let library = model.conceptLibrary
        library.mirror(withCommunity: community)
        // Authors' faces for the headset's cards, every ten minutes.
        PortraitPublisher.shared.publishIfDue(model: model)
        let settings = OrigamiLibrarySettings(
            modified: .now,
            conceptsFolder: OrigamiLibrarySettings.defaultConceptsFolder,
            conceptsSource: library.locationDescription,
            setBy: Host.current().localizedName ?? "the Mac")
        let held = OrigamiLibrarySettings.read(from: community)
        if held?.conceptsFolder != settings.conceptsFolder || held?.conceptsSource != settings.conceptsSource
            || held?.setBy != settings.setBy {
            OrigamiLibrarySettings.write(settings, to: community)
        }
    }

    /// One job begun: in the background (paced to the reader) or at once.
    private func begin(_ job: Job, model: AppModel, background: Bool) {
        let when = background ? ", when the Mac is idle…" : "\u{2026}"
        switch job {
        case .articleMetadata(let volumes):
            status = "Reading \(volumes.count) volume\(volumes.count == 1 ? "" : "s") for abstracts and keywords" + when
            ArticleEnrichment.shared.start(volumes: volumes, model: model, background: background)
        case .citedWorks:
            status = "Looking up the works your documents cite" + when
            let docs = model.index.allByID.mapValues(\.doc)
            CitedWorksCheck.shared.start(docs: docs, folder: model.index.folderURL, background: background)
            // Counted as looked up once the pass has had them.
            lookedUp.formUnion(docs.keys)
            UserDefaults.standard.set(Array(lookedUp), forKey: Self.lookedUpKey)
        case .corpus(let first, let name):
            status = "Finding the relations in \(name)" + when
            CorpusRelationsBuilder.shared.build(corpusOf: first, model: model, background: background)
        case .stances(let corpusID, let name, let pairs):
            status = "Reading how \(name)'s papers stand toward those they cite (\(pairs) pairs)" + when
            StanceFinder.shared.run(corpusID: corpusID, model: model, background: background)
        }
    }

    /// Check Metadata Now (2 Nov 2026): every job the library lacks, one
    /// after another, straight away — ignoring idle and the day's rest a
    /// job takes after a try. A pass already running in the background
    /// stops waiting for idle and carries on at once. Once each, then back
    /// to the quiet upkeep.
    func checkNow() {
        guard !isChecking, let model else { return }
        isChecking = true
        BackgroundPace.override = true
        status = "Checking now\u{2026}"
        Task {
            defer {
                isChecking = false
                BackgroundPace.override = false
            }
            // A background pass under way finishes first, now unpaced.
            while anyPassRunning { try? await Task.sleep(for: .seconds(2)) }
            StanceFinder.foldReviews(model: model)
            var done = Set<String>()
            // The online look-up of every cited work is the long one: it
            // waits until the metadata, relations and stances are done.
            var holding: Set<String> = ["cited"]
            while true {
                guard let (id, signature, job) = await nextJob(model: model, force: true,
                                                              skipping: done.union(holding)) else {
                    if holding.isEmpty { break }
                    holding = []
                    continue
                }
                done.insert(id)
                attempts[id] = (signature, .now)
                begin(job, model: model, background: false)
                // Each pass begins before the next is looked for.
                try? await Task.sleep(for: .milliseconds(300))
                while anyPassRunning { try? await Task.sleep(for: .seconds(2)) }
            }
            status = done.isEmpty
                ? "Checked now: nothing was missing \u{2014} \(model.epubRecords.count) documents."
                : "Checked now: \(done.count) job\(done.count == 1 ? "" : "s") done. Up to date."
        }
    }

    /// The first thing the library lacks, as a job id, what it would be
    /// tried on, and the job — nil when everything is in hand.
    private func nextJob(model: AppModel, force: Bool = false,
                         skipping skip: Set<String> = []) async -> (String, String, Job)? {
        func due(_ id: String, _ signature: String) -> Bool {
            if skip.contains(id) { return false }
            if force { return true }
            guard let last = attempts[id] else { return true }
            return last.signature != signature || Date.now.timeIntervalSince(last.at) > Self.retryAfter
        }

        // 1. Volumes with articles the metadata record has never read.
        let enrichment = ArticleEnrichment.shared
        let unread = model.epubRecords.filter { record in
            guard let bound = model.boundVolume(for: record) else { return false }
            let entries = enrichment.store[record.folder] ?? [:]
            return bound.works.contains { entries[$0.id] == nil }
        }
        if !unread.isEmpty {
            let signature = unread.map(\.folder).sorted().joined(separator: "|")
            if due("articles", signature) { return ("articles", signature, .articleMetadata(unread)) }
        }

        // 2. References never looked up, or a record a month old.
        if model.index.folderURL != nil {
            let ids = Set(model.index.allByID.keys)
            let fresh = ids.subtracting(lookedUp)
            let stale = CitedWorksCheck.shared.lastChecked.map { Date.now.timeIntervalSince($0) > 30 * 86_400 } ?? true
            if !fresh.isEmpty || stale {
                let signature = fresh.sorted().joined(separator: "|") + (stale ? "|stale" : "")
                if due("cited", signature) { return ("cited", signature, .citedWorks) }
            }
        }

        // 3. Series and journals whose relations are missing or behind.
        let builder = CorpusRelationsBuilder.shared
        let embeddings = await OrigamiLLM.shared.hasEmbeddingModel()
        for target in builder.allCorpora(in: model) {
            guard let first = target.volumes.first ?? target.papers.first else { continue }
            let members = Set((target.volumes + target.papers).map(\.folder))
            let built = builder.file?.corpora[target.id]
            let behind = built == nil
                || Set(built?.volumes ?? []) != members
                || built?.themes == nil
                || (embeddings && built?.meaning == nil)
            guard behind else { continue }
            let signature = members.sorted().joined(separator: "|") + (embeddings ? "|e" : "")
            if due("corpus:" + target.id, signature) {
                return ("corpus:" + target.id, signature, .corpus(first, name: target.name))
            }
        }

        // 4. Stances: citing pairs inside a corpus not yet read with the
        // current prompt — only once a model can answer.
        if OrigamiLLM.shared.canRespond {
            for (id, corpus) in builder.file?.corpora ?? [:] {
                let pending = StanceFinder.pendingPairs(in: corpus).count
                guard pending > 0 else { continue }
                let signature = "\(pending)|\(StanceFinder.promptVersion)"
                if due("stances:" + id, signature) {
                    return ("stances:" + id, signature, .stances(corpusID: id, name: corpus.name, pairs: pending))
                }
            }
        }
        return nil
    }
}

/// How a background pass keeps out of the reader's way: between steps it
/// waits until no key, click or touch has come for `quietAfter` seconds,
/// the Mac is not running hot, and Low Power Mode is off.
enum BackgroundPace {
    static let quietAfter: Double = 20

    /// Seconds since the last keyboard, mouse or trackpad input.
    static var idleSeconds: Double {
        guard let any = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    static var isQuiet: Bool {
        let info = ProcessInfo.processInfo
        return idleSeconds >= quietAfter
            && info.thermalState != .serious && info.thermalState != .critical
            && !info.isLowPowerModeEnabled
    }

    /// Check Metadata Now: every pass goes ahead without waiting.
    @MainActor static var override = false

    static func waitForQuiet() async {
        while !Task.isCancelled, !isQuiet, await !override {
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// Settings ▸ AI: the switch, what the upkeep is doing, and Check
/// Metadata Now — with the pass at work and how far it has got.
struct LibraryUpkeepSettingsSection: View {
    @State private var upkeep = LibraryUpkeep.shared

    /// The pass at work now, in a line — nil when none is.
    @MainActor static var activity: String? {
        let enrichment = ArticleEnrichment.shared
        if enrichment.isRunning {
            return "Article metadata: \(enrichment.done) of \(enrichment.total)"
                + (enrichment.current.map { " \u{2014} \($0)" } ?? "")
        }
        let cited = CitedWorksCheck.shared
        if cited.isRunning { return "Cited works: \(cited.done) of \(cited.total) looked up" }
        let builder = CorpusRelationsBuilder.shared
        if builder.isRunning { return "Corpus relations: " + (builder.log.last ?? "working") }
        let stances = StanceFinder.shared
        if stances.isRunning { return "Stances: " + (stances.log.last ?? "reading") }
        return nil
    }

    var body: some View {
        Section {
            Toggle("Keep the library\u{2019}s metadata up to date", isOn: Binding(
                get: { upkeep.isEnabled },
                set: { upkeep.isEnabled = $0 }))
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(upkeep.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let activity = Self.activity {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(activity).font(.caption).foregroundStyle(.primary)
                        }
                    }
                }
                Spacer()
                Button(upkeep.isChecking ? "Checking\u{2026}" : "Check Metadata Now") {
                    upkeep.checkNow()
                }
                .disabled(upkeep.isChecking)
                .help("Do every outstanding job once, now, without waiting for the Mac to be idle")
            }
        } header: {
            Text("Library Upkeep")
        } footer: {
            // (Check Metadata Now: once, straight away, not waiting for idle.)
            Text("""
                New documents get their abstracts and keywords, their cited works looked \
                up, and their series\u{2019} or journal\u{2019}s relations found \u{2014} in the background, \
                at low priority, and only while the Mac is left alone for a moment, so \
                reading is never slowed.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
