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
///    (`CorpusRelationsBuilder`).
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

    func start(model: AppModel) {
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
    }

    private var anyPassRunning: Bool {
        ArticleEnrichment.shared.isRunning || CitedWorksCheck.shared.isRunning
            || CorpusRelationsBuilder.shared.isRunning
    }

    private func tick(model: AppModel) async {
        guard isEnabled else { status = "Off."; return }
        guard !anyPassRunning else { return }
        guard !model.epubRecords.isEmpty else { status = "No documents yet."; return }
        guard let (id, signature, job) = await nextJob(model: model) else {
            status = "Up to date — \(model.epubRecords.count) documents."
            return
        }
        attempts[id] = (signature, .now)
        switch job {
        case .articleMetadata(let volumes):
            status = "Reading \(volumes.count) volume\(volumes.count == 1 ? "" : "s") for abstracts and keywords, when the Mac is idle…"
            ArticleEnrichment.shared.start(volumes: volumes, model: model, background: true)
        case .citedWorks:
            status = "Looking up the works your documents cite, when the Mac is idle…"
            let docs = model.index.allByID.mapValues(\.doc)
            CitedWorksCheck.shared.start(docs: docs, folder: model.index.folderURL, background: true)
            // Counted as looked up once the pass has had them.
            lookedUp.formUnion(docs.keys)
            UserDefaults.standard.set(Array(lookedUp), forKey: Self.lookedUpKey)
        case .corpus(let first, let name):
            status = "Finding the relations in \(name), when the Mac is idle…"
            CorpusRelationsBuilder.shared.build(corpusOf: first, model: model, background: true)
        }
        // The pass reports its own progress; the upkeep waits it out.
        while anyPassRunning, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The first thing the library lacks, as a job id, what it would be
    /// tried on, and the job — nil when everything is in hand.
    private func nextJob(model: AppModel) async -> (String, String, Job)? {
        func due(_ id: String, _ signature: String) -> Bool {
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

    static func waitForQuiet() async {
        while !Task.isCancelled, !isQuiet {
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// Settings ▸ AI: the switch, and what the upkeep is doing.
struct LibraryUpkeepSettingsSection: View {
    @State private var upkeep = LibraryUpkeep.shared

    var body: some View {
        Section {
            Toggle("Keep the library\u{2019}s metadata up to date", isOn: Binding(
                get: { upkeep.isEnabled },
                set: { upkeep.isEnabled = $0 }))
            Text(upkeep.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Library Upkeep")
        } footer: {
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
