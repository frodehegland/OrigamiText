import SwiftUI
import NaturalLanguage

// MARK: - The engine

/// K. Nav — Knowledge Navigator, from Tom's spec: make augmented
/// thinking visible at corpus scale. Two modes over the library's
/// paragraphs: **clusters**, the strong, expected groupings (a solved
/// problem, done plainly), and **bridges**, the point of the tool —
/// pairs with *low* surface similarity that are nonetheless structurally
/// related, Granovetter's weak ties. Every cluster and bridge carries a
/// reasoning trace as a first-class output: what was compared, what
/// scored what, and why a low-similarity pair was judged significant
/// rather than noise. Everything runs on this Mac — embeddings are the
/// system's own (NaturalLanguage), and the traces are computed, never
/// generated, so the trace cannot hallucinate.
nonisolated enum KNavEngine {

    /// One unit of content: a paragraph, the library's addressable
    /// granularity (the spec's open question §8, answered by the format).
    struct Unit: Identifiable, Sendable {
        let id: String          // docID#paragraphID
        let docID: String
        let paragraphID: String
        let docTitle: String
        let author: String
        let text: String
        var vector: [Double] = []
    }

    struct Parameters: Sendable {
        var mode: Mode = .bridges
        /// The truncation threshold: pairs at or above it form the
        /// cluster graph; pairs *below* it are where bridges are sought —
        /// sweep it to learn where the useful bridges live.
        var threshold: Double = 0.6
        /// The experimental arm (§5a): seeded random sign-projection of
        /// the embedding space before comparison — controlled randomness
        /// against the overly clean solution. Off = the exact baseline.
        var sketch = false
        var seed: UInt64 = 42
    }

    enum Mode: String, CaseIterable, Sendable {
        case clusters = "Clusters"
        case bridges = "Bridges"
    }

    struct Cluster: Identifiable, Sendable {
        let id: Int
        let unitIDs: [String]
        let trace: String
    }

    struct Bridge: Identifiable, Sendable {
        let a: String
        let b: String
        let mediator: String
        let directSimilarity: Double
        let mediatedSimilarity: Double
        /// mediated minus direct — how much more these two share through
        /// their mediator than face to face.
        let score: Double
        let strong: Bool
        let trace: String
        var id: String { "\(a)↔\(b)" }
    }

    /// One run, whole: its parameters and everything found, so runs at
    /// different thresholds and seeds stand side by side (§4.6).
    struct Run: Identifiable, Sendable {
        let id = UUID()
        let parameters: Parameters
        let unitCount: Int
        let clusters: [Cluster]
        let bridges: [Bridge]
        let note: String
    }

    /// Embeds every unit with the system sentence embedding (word
    /// embedding averaged as the fallback). Returns nil when the Mac
    /// offers neither.
    static func embed(_ units: [Unit]) -> [Unit]? {
        if let sentence = NLEmbedding.sentenceEmbedding(for: .english) {
            return units.compactMap { unit in
                guard let vector = sentence.vector(for: unit.text) else { return nil }
                var embedded = unit
                embedded.vector = vector
                return embedded
            }
        }
        guard let word = NLEmbedding.wordEmbedding(for: .english) else { return nil }
        return units.compactMap { unit in
            var sum = [Double](repeating: 0, count: word.dimension)
            var counted = 0
            for token in unit.text.lowercased().split(whereSeparator: { !$0.isLetter }) {
                guard let vector = word.vector(for: String(token)) else { continue }
                for index in vector.indices { sum[index] += vector[index] }
                counted += 1
            }
            guard counted > 0 else { return nil }
            var embedded = unit
            embedded.vector = sum.map { $0 / Double(counted) }
            return embedded
        }
    }

    /// The whole diagnostic, off the main thread: similarity space
    /// (sketched or exact), clusters at the threshold, bridges below it.
    static func compute(units: [Unit], parameters: Parameters) -> Run {
        var vectors = units.map(\.vector)
        var note = "\(units.count) paragraphs compared"
        if parameters.sketch {
            vectors = sketch(vectors, seed: parameters.seed)
            note += " · sketched (seed \(parameters.seed))"
        } else {
            note += " · exact baseline"
        }
        let n = units.count
        var similarity = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let value = cosine(vectors[i], vectors[j])
                similarity[i][j] = value
                similarity[j][i] = value
            }
        }
        let clusterIndex = componentClusters(similarity: similarity, threshold: parameters.threshold)
        let clusters = describeClusters(units: units, similarity: similarity,
                                        membership: clusterIndex, threshold: parameters.threshold)
        let bridges = findBridges(units: units, similarity: similarity,
                                  membership: clusterIndex, threshold: parameters.threshold)
        return Run(parameters: parameters, unitCount: n,
                   clusters: clusters, bridges: bridges, note: note)
    }

    // MARK: The similarity space

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, magA = 0.0, magB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            magA += a[index] * a[index]
            magB += b[index] * b[index]
        }
        let magnitude = (magA * magB).squareRoot()
        return magnitude > 0 ? dot / magnitude : 0
    }

    /// The experimental arm: a seeded random sign projection (a classic
    /// sketch) to a quarter of the dimensions. Deliberate, controlled
    /// randomness in the reduction — the hypothesis under test, not a
    /// known-good algorithm.
    static func sketch(_ vectors: [[Double]], seed: UInt64) -> [[Double]] {
        guard let dimension = vectors.first?.count, dimension > 8 else { return vectors }
        let reduced = max(dimension / 4, 8)
        var generator = SplitMix64(seed: seed)
        // One shared projection: rows of random signs.
        var projection: [[Double]] = []
        for _ in 0..<reduced {
            projection.append((0..<dimension).map { _ in
                Bool.random(using: &generator) ? 1.0 : -1.0
            })
        }
        return vectors.map { vector in
            projection.map { row in
                var sum = 0.0
                for index in vector.indices { sum += row[index] * vector[index] }
                return sum
            }
        }
    }

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Clusters — the solved problem, done plainly

    /// Connected components over the graph of pairs at or above the
    /// threshold: the strong, expected groupings.
    static func componentClusters(similarity: [[Double]], threshold: Double) -> [Int] {
        let n = similarity.count
        var membership = Array(0..<n)
        func root(_ index: Int) -> Int {
            var current = index
            while membership[current] != current { current = membership[current] }
            return current
        }
        for i in 0..<n {
            for j in (i + 1)..<n where similarity[i][j] >= threshold {
                membership[root(j)] = root(i)
            }
        }
        return (0..<n).map { root($0) }
    }

    static func describeClusters(units: [Unit], similarity: [[Double]],
                                 membership: [Int], threshold: Double) -> [Cluster] {
        var groups: [Int: [Int]] = [:]
        for (index, group) in membership.enumerated() {
            groups[group, default: []].append(index)
        }
        var clusters: [Cluster] = []
        for (_, members) in groups where members.count >= 2 {
            var lowest = 1.0, highest = 0.0
            for i in members {
                for j in members where j > i {
                    lowest = min(lowest, similarity[i][j])
                    highest = max(highest, similarity[i][j])
                }
            }
            let documents = Set(members.map { units[$0].docTitle })
            let trace = "Grouped because every member is reachable through pairwise "
                + "similarity ≥ \(String(format: "%.2f", threshold)) (the truncation threshold). "
                + "Internal similarities run \(String(format: "%.2f", lowest))–\(String(format: "%.2f", highest)). "
                + "\(members.count) paragraphs from \(documents.count) document\(documents.count == 1 ? "" : "s") — "
                + (documents.count == 1
                   ? "one document talking to itself, the expected kind of grouping."
                   : "several documents converging, a grouping worth reading.")
            clusters.append(Cluster(id: clusters.count,
                                    unitIDs: members.map { units[$0].id },
                                    trace: trace))
        }
        return clusters.sorted { $0.unitIDs.count > $1.unitIDs.count }
    }

    // MARK: Bridges — the point of the tool

    /// A bridge: two paragraphs from different documents and different
    /// clusters whose direct similarity fell below the truncation
    /// threshold — the pairs the reduction throws away — yet which share
    /// a mediator both speak to. The score is what they share through
    /// the mediator minus what they share face to face; the trace is the
    /// case, and the case is checkable by reading.
    static func findBridges(units: [Unit], similarity: [[Double]],
                            membership: [Int], threshold: Double) -> [Bridge] {
        let n = units.count
        var bridges: [Bridge] = []
        for a in 0..<n {
            for b in (a + 1)..<n {
                guard units[a].docID != units[b].docID,
                      membership[a] != membership[b],
                      similarity[a][b] < threshold else { continue }
                // The best mediator: the unit both ends speak to most.
                var bestMediator = -1
                var bestMediated = 0.0
                for m in 0..<n where m != a && m != b {
                    let mediated = min(similarity[a][m], similarity[b][m])
                    if mediated > bestMediated {
                        bestMediated = mediated
                        bestMediator = m
                    }
                }
                guard bestMediator >= 0 else { continue }
                let direct = similarity[a][b]
                let score = bestMediated - direct
                guard score > 0.12, bestMediated > 0.35 else { continue }
                let strong = score > 0.25 && bestMediated > 0.5
                let mediator = units[bestMediator]
                let trace = "Direct similarity is only \(String(format: "%.2f", direct)) — "
                    + "below the truncation threshold of \(String(format: "%.2f", threshold)), so any "
                    + "reduction keeping only strong signals discards this pair. Yet both speak to a third "
                    + "paragraph — “\(mediator.docTitle)” [\(mediator.id)] — at "
                    + "\(String(format: "%.2f", similarity[a][bestMediator])) and "
                    + "\(String(format: "%.2f", similarity[b][bestMediator])). They sit in different "
                    + "clusters and different documents: a weak tie joining otherwise-separate "
                    + "neighborhoods (Granovetter 1973). Score \(String(format: "%.2f", score)) = mediated "
                    + "\(String(format: "%.2f", bestMediated)) − direct \(String(format: "%.2f", direct)). "
                    + (strong
                       ? "Strong signal — the mediation is well above noise."
                       : "Weak signal — worth a human look, and honestly marked as such.")
                bridges.append(Bridge(a: units[a].id, b: units[b].id,
                                      mediator: mediator.id,
                                      directSimilarity: direct,
                                      mediatedSimilarity: bestMediated,
                                      score: score, strong: strong, trace: trace))
            }
        }
        // The best bridge per document pair, strongest first, a dozen at
        // most — a diagnostic reads a page, not a firehose.
        var byDocumentPair: [String: Bridge] = [:]
        for bridge in bridges {
            let docs = [String(bridge.a.split(separator: "#")[0]),
                        String(bridge.b.split(separator: "#")[0])].sorted().joined(separator: "|")
            if let existing = byDocumentPair[docs], existing.score >= bridge.score { continue }
            byDocumentPair[docs] = bridge
        }
        return byDocumentPair.values.sorted { $0.score > $1.score }.prefix(12).map { $0 }
    }
}

// MARK: - The view

/// K. Nav: the Knowledge Navigator diagnostic as a library view. Choose
/// the mode, set the truncation threshold, optionally turn on the
/// sketch (seeded randomness in the reduction — the spec's hypothesis
/// under test) and run; every run is kept in the session so thresholds
/// and seeds can be compared side by side. Clusters are the expected
/// groupings; bridges are the low-similarity, cross-document pairs a
/// truncation would discard, each with the reasoning trace that makes
/// it checkable — read both ends side by side and judge.
struct KNavView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: KNavEngine.Mode = .bridges
    @State private var threshold = 0.6
    @State private var sketch = false
    @State private var seed = 42
    @State private var runs: [KNavEngine.Run] = []
    @State private var selectedRunID: UUID?
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var unfurled: Set<String> = []
    /// Units by id, kept from the latest embedding so results resolve to
    /// text and documents.
    @State private var unitsByID: [String: KNavEngine.Unit] = [:]

    private var selectedRun: KNavEngine.Run? {
        runs.first { $0.id == selectedRunID } ?? runs.last
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if !runs.isEmpty {
                runStrip
                Divider()
            }
            results
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(KNavEngine.Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("Clusters: the strong, expected groupings. Bridges: the low-similarity, cross-document connections a truncation would throw away — the point of the tool.")
            HStack(spacing: 6) {
                Text("Truncation")
                Slider(value: $threshold, in: 0.35...0.85)
                    .frame(width: 140)
                Text(String(format: "%.2f", threshold))
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .leading)
            }
            .help("The truncation threshold: pairs at or above it form clusters; bridges are sought among the pairs below it. Sweep it across runs to learn where the useful bridges live.")
            Toggle("Sketch", isOn: $sketch)
                .toggleStyle(.checkbox)
                .help("The experimental arm: seeded random sign-projection of the embedding space before comparison — controlled randomness against an overly clean reduction. Off is the exact baseline.")
            if sketch {
                Stepper("Seed \(seed)", value: $seed, in: 1...999)
                    .font(.caption)
                    .fixedSize()
            }
            Button {
                run()
            } label: {
                Label(isRunning ? "Comparing…" : "Run", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .disabled(isRunning)
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
        .font(.callout)
        .padding(10)
    }

    /// Every run of the session, side by side — the comparison the
    /// diagnostic exists for.
    private var runStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(runs) { run in
                    let isSelected = run.id == (selectedRun?.id)
                    Button {
                        selectedRunID = run.id
                    } label: {
                        Text(label(for: run))
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.15))
                                                   : AnyShapeStyle(.quaternary.opacity(0.5)),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(
                                isSelected ? Color.accentColor : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }

    private func label(for run: KNavEngine.Run) -> String {
        let sketchPart = run.parameters.sketch ? " · seed \(run.parameters.seed)" : " · exact"
        let counts = "\(run.clusters.count) clusters, \(run.bridges.count) bridges"
        return "τ \(String(format: "%.2f", run.parameters.threshold))\(sketchPart) → \(counts)"
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let run = selectedRun {
                    Text(run.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if mode == .clusters {
                        if run.clusters.isEmpty {
                            Text("No cluster holds at this threshold — lower it and run again.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(run.clusters) { cluster in
                            clusterRow(cluster)
                        }
                    } else {
                        if run.bridges.isEmpty {
                            Text("No defensible bridge at this threshold — an honest empty answer. Try other thresholds and seeds; over-conservative and over-permissive are both findings.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(run.bridges) { bridge in
                            bridgeRow(bridge)
                        }
                    }
                } else if !isRunning {
                    Text("K. Nav — the Knowledge Navigator diagnostic, from Tom's spec, run over this library's paragraphs. Clusters finds the strong, expected groupings; Bridges finds the pairs with low surface similarity that are nonetheless structurally related — Granovetter's weak ties, the connections worth surfacing. Every result carries its reasoning trace: computed, not generated, so the trace cannot hallucinate. Embeddings are the system's own; nothing leaves this Mac. Run at several thresholds — the runs stand side by side.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    @ViewBuilder
    private func clusterRow(_ cluster: KNavEngine.Cluster) -> some View {
        let key = "c\(cluster.id)"
        Button {
            withAnimation(.snappy) {
                if unfurled.contains(key) { unfurled.remove(key) } else { unfurled.insert(key) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: unfurled.contains(key) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(clusterTitle(cluster))
                    .font(.system(size: 17, weight: .bold, design: .serif))
                Text("\(cluster.unitIDs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        if unfurled.contains(key) {
            Text(cluster.trace)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            ForEach(cluster.unitIDs, id: \.self) { unitID in
                if let unit = unitsByID[unitID] {
                    unitRow(unit)
                }
            }
        }
    }

    private func clusterTitle(_ cluster: KNavEngine.Cluster) -> String {
        let titles = cluster.unitIDs.compactMap { unitsByID[$0]?.docTitle }
        let distinct = Array(Set(titles)).sorted()
        return distinct.prefix(2).joined(separator: " · ")
            + (distinct.count > 2 ? " · …" : "")
    }

    @ViewBuilder
    private func bridgeRow(_ bridge: KNavEngine.Bridge) -> some View {
        let key = bridge.id
        Button {
            withAnimation(.snappy) {
                if unfurled.contains(key) { unfurled.remove(key) } else { unfurled.insert(key) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: unfurled.contains(key) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(unitsByID[bridge.a]?.docTitle ?? "?") ↔ \(unitsByID[bridge.b]?.docTitle ?? "?")")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                Text(bridge.strong ? "strong" : "worth a look")
                    .font(.caption)
                    .foregroundStyle(bridge.strong ? Color.green.mix(with: .black, by: 0.25) : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(String(format: "%.2f", bridge.score))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        if unfurled.contains(key) {
            if let a = unitsByID[bridge.a] { unitRow(a) }
            if let b = unitsByID[bridge.b] { unitRow(b) }
            Text(bridge.trace)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            if let a = unitsByID[bridge.a], let b = unitsByID[bridge.b],
               let docA = model.index.byID[a.docID]?.doc,
               let docB = model.index.byID[b.docID]?.doc {
                Button("Read Both Side by Side") {
                    model.openTranspointing(from: docA, to: docB)
                }
                .controlSize(.small)
                .padding(.leading, 18)
                .help("Transpointing windows: both documents, the judgement is yours")
            }
        }
    }

    private func unitRow(_ unit: KNavEngine.Unit) -> some View {
        Button {
            if let doc = model.index.byID[unit.docID]?.doc {
                model.open(doc, fragment: unit.paragraphID)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(unit.docTitle) — \(unit.author) [\(unit.id)]")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(unit.text)
                    .font(.system(size: 12))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
        .help("Read it in place")
    }

    // MARK: Running

    /// Gathers the corpus (paragraphs of every text document, bots and
    /// trails and glossaries excluded, capped for the phone-book case),
    /// embeds it once per session shape, and computes off the main
    /// thread.
    private func run() {
        errorText = nil
        isRunning = true
        var units: [KNavEngine.Unit] = []
        let entries = model.filteredEntries
            .filter { $0.doc.body != nil }
            .filter { $0.doc.documentType != BotDocument.documentType }
            .filter { $0.doc.documentType != TrailDocument.documentType }
            .filter { $0.doc.documentType != PersonalGlossary.documentType }
        for entry in entries {
            let appendixIDs = entry.doc.visualMetaParagraphIDs
            var taken = 0
            for paragraph in (entry.doc.body ?? []) {
                guard taken < 30, units.count < 400 else { break }
                guard !appendixIDs.contains(paragraph.id),
                      paragraph.effectiveHeading == nil,
                      paragraph.displayText.count >= 60 else { continue }
                units.append(KNavEngine.Unit(id: "\(entry.id)#\(paragraph.id)",
                                             docID: entry.id,
                                             paragraphID: paragraph.id,
                                             docTitle: entry.doc.title,
                                             author: entry.doc.displayAuthor,
                                             text: paragraph.displayText))
                taken += 1
            }
        }
        guard units.count >= 3 else {
            errorText = "Not enough substantial paragraphs to compare — the diagnostic needs at least a few."
            isRunning = false
            return
        }
        let parameters = KNavEngine.Parameters(mode: mode, threshold: threshold,
                                               sketch: sketch, seed: UInt64(seed))
        Task.detached(priority: .userInitiated) {
            guard let embedded = KNavEngine.embed(units) else {
                await MainActor.run {
                    errorText = "No on-device embedding is available on this Mac (NaturalLanguage offered neither a sentence nor a word embedding for English)."
                    isRunning = false
                }
                return
            }
            guard embedded.count >= 3 else {
                await MainActor.run {
                    errorText = "The embedding covered too few paragraphs to compare."
                    isRunning = false
                }
                return
            }
            let run = KNavEngine.compute(units: embedded, parameters: parameters)
            await MainActor.run {
                unitsByID = Dictionary(uniqueKeysWithValues: embedded.map { ($0.id, $0) })
                runs.append(run)
                selectedRunID = run.id
                unfurled = []
                isRunning = false
            }
        }
    }
}

extension KNavView {
    /// K. Nav as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "k-nav",
        name: "K. Nav",
        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(KNavView()) },
        hidesDocumentList: true
    )
}
