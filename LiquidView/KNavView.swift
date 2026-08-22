import SwiftUI
import NaturalLanguage
import FoundationModels

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

    /// A pair of units the run found tied at or above the threshold —
    /// the weave presentation's strong threads.
    struct Edge: Sendable {
        let a: String
        let b: String
    }

    /// One run, whole: its parameters and everything found, so runs at
    /// different thresholds and seeds stand side by side (§4.6).
    struct Run: Identifiable, Sendable {
        let id = UUID()
        let parameters: Parameters
        let unitCount: Int
        let clusters: [Cluster]
        let bridges: [Bridge]
        let clusterEdges: [Edge]
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
        var clusterEdges: [Edge] = []
        outer: for i in 0..<n {
            for j in (i + 1)..<n where similarity[i][j] >= parameters.threshold {
                clusterEdges.append(Edge(a: units[i].id, b: units[j].id))
                if clusterEdges.count >= 1200 { break outer }   // stay legible and fast
            }
        }
        return Run(parameters: parameters, unitCount: n,
                   clusters: clusters, bridges: bridges,
                   clusterEdges: clusterEdges, note: note)
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

// MARK: - Keyword stances, as the model returns them

/// One connected paragraph's stance toward the typed keyword, grounded
/// by address before display like every AI view's output.
@Generable
nonisolated struct GeneratedKeywordStance {
    @Guide(description: "The paragraph's address, copied exactly from its == line")
    var address: String
    @Guide(description: "The paragraph's stance toward the keyword", .anyOf(["positive", "negative", "neutral", "questions"]))
    var stance: String
}

@Generable
nonisolated struct GeneratedKeywordStances {
    @Guide(description: "One stance for every paragraph given, in the order given")
    var stances: [GeneratedKeywordStance]
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
    @State private var presentation: Presentation = .list
    @State private var threshold = 0.6

    /// How a run is shown: the list carries the traces; the weave is
    /// the wheel — paragraphs as knots of light grouped by document,
    /// strong ties as the breathing field, and the bridges as bright
    /// dashed threads. Hover a knot and its threads flare; drag to
    /// spin; click a knot to read the paragraph in place.
    private enum Presentation: String, CaseIterable {
        case list = "List"
        case weave = "Weave"
    }
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
    /// The probe: the typed text, and its kinship to every compared
    /// paragraph — shown at the hub of the weave with threads outward,
    /// each colored by the paragraph's stance toward the keyword once
    /// the on-device model has read it.
    @State private var probeText = ""
    @State private var probeResult: (text: String, threads: [(unitID: String, strength: Double, stance: ProbeStance?)])?
    /// True while the on-device model is reading the connected
    /// paragraphs for their stances; the threads stand white meanwhile.
    @State private var stancesPending = false
    /// A probe typed before any run exists waits for the run to finish.
    @State private var pendingProbe: String?

    /// A connected paragraph's stance toward the keyword, and the color
    /// its thread takes: for the keyword green, against it red, merely
    /// speaking of it blue, asking about it orange.
    enum ProbeStance: String, Sendable {
        case positive, negative, neutral, questions

        var color: Color {
            switch self {
            case .positive: .green
            case .negative: .red
            case .neutral: .blue
            case .questions: .orange
            }
        }

        var label: String {
            switch self {
            case .positive: "positive"
            case .negative: "negative"
            case .neutral: "neutral"
            case .questions: "questions it"
            }
        }
    }

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
            TextField("Hold a thought to the weave…", text: $probeText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(submitProbe)
                .help("Press Return and your words stand at the hub of the weave, with threads of kinship out to the paragraphs closest to them — same on-device embedding, computed exactly. Submit empty to clear.")
            Picker("Presentation", selection: $presentation) {
                ForEach(Presentation.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            .help("List carries the reasoning traces; Weave is the wheel — knots by document, strong ties as the field, bridges as bright dashed threads. Hover to flare, drag to spin, click a knot to read.")
        }
        .font(.callout)
        .padding(10)
    }

    // MARK: The probe

    /// Return holds the typed words to the weave: they are embedded like
    /// any paragraph and threaded to their nearest kin. An empty submit
    /// clears the probe; a probe before any run waits for the first one.
    private func submitProbe() {
        let text = probeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            probeResult = nil
            pendingProbe = nil
            return
        }
        presentation = .weave
        if unitsByID.isEmpty {
            pendingProbe = text
            if !isRunning { run() }
            return
        }
        computeProbe(text)
    }

    private func computeProbe(_ text: String) {
        let units = Array(unitsByID.values)
        stancesPending = false
        Task.detached(priority: .userInitiated) {
            let seed = KNavEngine.Unit(id: "probe", docID: "", paragraphID: "",
                                       docTitle: "", author: "", text: text)
            guard let embedded = KNavEngine.embed([seed])?.first else {
                await MainActor.run {
                    errorText = "No on-device embedding is available for the probe."
                }
                return
            }
            // Kinship is always computed exactly — the probe is a reading
            // aid, not part of the experiment's sketched arm.
            let floor = 0.3
            let threads = units
                .map { (unitID: $0.id,
                        similarity: KNavEngine.cosine(embedded.vector, $0.vector)) }
                .filter { $0.similarity >= floor }
                .sorted { $0.similarity > $1.similarity }
                .prefix(12)
                .map { (unitID: $0.unitID,
                        strength: min(max(($0.similarity - floor) / 0.4, 0), 1),
                        stance: ProbeStance?.none) }
            let modelReady: Bool = {
                if case .available = SystemLanguageModel.default.availability { return true }
                return false
            }()
            await MainActor.run {
                probeResult = (text: text, threads: Array(threads))
                stancesPending = modelReady && !threads.isEmpty
            }
            // The stances: one grounded call over just the connected
            // paragraphs — each thread colored by what its paragraph
            // holds toward the keyword. Without Apple Intelligence the
            // threads simply stay white; kinship alone is still honest.
            guard modelReady, !threads.isEmpty else { return }
            let byID = Dictionary(uniqueKeysWithValues: units.map { ($0.id, $0) })
            var prompt = """
            A reader typed a keyword over a library of documents. For each paragraph below, judge the paragraph's stance toward the keyword: "positive" when it speaks for it, supports it, or treats it favorably; "negative" when it speaks against it or treats it unfavorably; "questions" when it asks about, doubts, or challenges it; "neutral" when it merely mentions or relates to it without judgement. Each paragraph begins with a == line giving its address — copy addresses exactly. Judge every paragraph given, no others.

            THE KEYWORD: \(text)

            THE PARAGRAPHS:

            """
            for thread in threads {
                guard let unit = byID[thread.unitID] else { continue }
                prompt += "== [\(unit.id)]\n\(String(unit.text.prefix(400)))\n\n"
            }
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt,
                                                         generating: GeneratedKeywordStances.self)
                var stanceByID: [String: ProbeStance] = [:]
                for judged in response.content.stances {
                    let id = judged.address.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    if let stance = ProbeStance(rawValue: judged.stance) {
                        stanceByID[id] = stance
                    }
                }
                await MainActor.run {
                    // A newer probe may have replaced this one meanwhile.
                    guard probeResult?.text == text else { return }
                    probeResult = (text: text, threads: threads.map {
                        (unitID: $0.unitID, strength: $0.strength, stance: stanceByID[$0.unitID])
                    })
                    stancesPending = false
                }
            } catch {
                await MainActor.run {
                    if probeResult?.text == text { stancesPending = false }
                }
            }
        }
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
        if presentation == .weave, let run = selectedRun {
            weave(for: run)
        } else {
            list
        }
    }

    // MARK: The weave presentation

    /// The run on the wheel: every compared paragraph a knot of light,
    /// documents around the rim where the Weave puts authors, the strong
    /// ties (≥ τ) as the breathing field, and the bridges — the point of
    /// the tool — as the bright dashed threads joining distant arcs.
    private func weave(for run: KNavEngine.Run) -> some View {
        let built = weaveData(for: run)
        var probe: WeaveProbe?
        if let probeResult {
            probe = WeaveProbe(
                label: probeResult.text,
                threads: probeResult.threads.compactMap { thread in
                    built.indexByID[thread.unitID].map {
                        (node: $0, strength: thread.strength, tint: thread.stance?.color)
                    }
                })
        }
        return WeaveCanvas(
            data: built.data,
            onOpen: { unitID in
                if let unit = unitsByID[unitID],
                   let doc = model.index.byID[unit.docID]?.doc {
                    model.open(doc, fragment: unit.paragraphID)
                }
            },
            title: "K. Nav",
            subtitle: "\(built.data.nodes.count) paragraphs · \(built.data.edges.count) strong ties · \(built.bright.count) bridges — τ \(String(format: "%.2f", run.parameters.threshold))\(run.parameters.sketch ? " · seed \(run.parameters.seed)" : " · exact")",
            brightEdges: built.bright,
            probe: probe)
        .overlay(alignment: .bottom) {
            if probeResult != nil {
                stanceLegend
            }
        }
    }

    /// What the probe's colors mean, standing where the Weave puts its
    /// captions. White while stances are still being read.
    private var stanceLegend: some View {
        HStack(spacing: 12) {
            if stancesPending {
                ProgressView()
                    .controlSize(.mini)
                Text("reading stances toward “\(String(probeText.prefix(24)))”…")
            } else {
                stanceSwatch(.positive)
                stanceSwatch(.negative)
                stanceSwatch(.neutral)
                stanceSwatch(.questions)
            }
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color(white: 0.35))
                    .frame(width: 14, height: 2)
                Text("everything else")
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.white.opacity(0.08), in: Capsule())
        .padding(.bottom, 10)
        .allowsHitTesting(false)
    }

    private func stanceSwatch(_ stance: ProbeStance) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(stance.color)
                .frame(width: 14, height: 2)
            Text(stance.label)
        }
    }

    private func weaveData(for run: KNavEngine.Run) -> (data: WeaveData, bright: [WeaveEdge],
                                                        indexByID: [String: Int]) {
        // Documents around the wheel, their paragraphs in body order —
        // time runs along each document's arc, as it does for the
        // Weave's authors.
        let units = unitsByID.values.sorted {
            ($0.docTitle, paragraphNumber($0.paragraphID)) < ($1.docTitle, paragraphNumber($1.paragraphID))
        }
        var data = WeaveData()
        var indexByID: [String: Int] = [:]
        // Bridge participation makes the knot: bridges are what the
        // wheel exists to show.
        var weight: [String: Int] = [:]
        for bridge in run.bridges {
            weight[bridge.a, default: 0] += 4
            weight[bridge.b, default: 0] += 4
            weight[bridge.mediator, default: 0] += 2
        }
        for edge in run.clusterEdges {
            weight[edge.a, default: 0] += 1
            weight[edge.b, default: 0] += 1
        }
        let documents = Array(Set(units.map(\.docTitle))).sorted()
        let hueByDocument = Dictionary(uniqueKeysWithValues: documents.enumerated().map {
            ($1, Double($0) / Double(max(documents.count, 1)))
        })
        var arcStart = 0
        var arcDocument: String?
        for unit in units {
            if unit.docTitle != arcDocument {
                if let name = arcDocument, data.nodes.count > arcStart {
                    data.authorArcs.append((String(name.prefix(22)),
                                            hueByDocument[name] ?? 0,
                                            arcStart...(data.nodes.count - 1)))
                }
                arcDocument = unit.docTitle
                arcStart = data.nodes.count
            }
            indexByID[unit.id] = data.nodes.count
            data.nodes.append(WeaveNode(id: unit.id,
                                        title: String(unit.text.prefix(90)),
                                        author: unit.docTitle,
                                        weight: weight[unit.id] ?? 0,
                                        hue: hueByDocument[unit.docTitle] ?? 0))
        }
        if let name = arcDocument, data.nodes.count > arcStart {
            data.authorArcs.append((String(name.prefix(22)),
                                    hueByDocument[name] ?? 0,
                                    arcStart...(data.nodes.count - 1)))
        }
        for edge in run.clusterEdges {
            guard let from = indexByID[edge.a], let to = indexByID[edge.b] else { continue }
            data.edges.append(WeaveEdge(from: from, to: to))
        }
        var bright: [WeaveEdge] = []
        for bridge in run.bridges {
            guard let from = indexByID[bridge.a], let to = indexByID[bridge.b] else { continue }
            bright.append(WeaveEdge(from: from, to: to))
        }
        return (data, bright, indexByID)
    }

    private func paragraphNumber(_ paragraphID: String) -> Int {
        Int(paragraphID.drop(while: { !$0.isNumber })) ?? 0
    }

    // MARK: The list presentation

    @ViewBuilder
    private var list: some View {
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
                    .font(AppFonts.body(17, weight: .bold))
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
                    .font(AppFonts.body(17, weight: .bold))
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
                // A thought held to the weave before the first run was
                // waiting for these vectors.
                if let waiting = pendingProbe {
                    pendingProbe = nil
                    computeProbe(waiting)
                }
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
