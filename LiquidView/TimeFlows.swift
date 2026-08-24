// The Time Flows: the data lines standing along the headset corridor's
// Z axis, curated on the Mac for easy access there. The + dialog is
// Liquid Information's Ask-for-Data brought across (keep in step): the
// request is interpreted on-device, the data fetched from the real
// providers — or the user's own file parsed deterministically — and
// each fetched series is reduced to one point per year (the corridor's
// unit) and written into the community-folder mirror the headset reads.
#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// One sample in a fetched series — ported from Liquid Information's
/// SceneDocument (the fetchers speak this type).
nonisolated struct SeriesPoint: Codable, Hashable, Sendable {
    var date: Date
    var value: Double
    /// Optional name for the sample — the category column of a timeless
    /// table ("Norway", "Sweden"). Shown beneath the point when present.
    var label: String?

    init(date: Date, value: Double, label: String? = nil) {
        self.date = date
        self.value = value
        self.label = label
    }
}

// MARK: - The mirror's Mac-side hands

extension AppModel {

    /// The flows as the mirror holds them, grouped by pair.
    func timeFlowPairs() -> [(pair: String, name: String, series: [SankeySpace.Series])] {
        guard let folder = index.folderURL else { return [] }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return SankeySpace.read(from: folder)?.pairs ?? []
    }

    /// Fetched series join the corridor: each reduced to one point per
    /// year — the year's mean — and written to the mirror the headset
    /// adopts on its next scan.
    func addTimeFlows(_ fetched: [FetchedSeries]) {
        guard let folder = index.folderURL, !fetched.isEmpty else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var dataset = SankeySpace.read(from: folder)
            ?? SankeySpace.Dataset(series: [], modified: .now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        for series in fetched where !series.timeless {
            var sums: [Int: (total: Double, count: Int)] = [:]
            for point in series.points {
                let year = calendar.component(.year, from: point.date)
                let sum = sums[year] ?? (0, 0)
                sums[year] = (sum.total + point.value, sum.count + 1)
            }
            let values = sums.keys.sorted().map {
                SankeySpace.Series.YearValue(
                    year: $0, value: sums[$0]!.total / Double(sums[$0]!.count))
            }
            guard values.count >= 2 else { continue }
            let pair = series.label.lowercased()
                .replacingOccurrences(of: " ", with: "-")
            dataset.series.removeAll { $0.pair == pair }
            dataset.series.append(SankeySpace.Series(
                id: pair, pair: pair, name: series.label, role: .max,
                unit: series.unit, values: values))
        }
        dataset.modified = .now
        SankeySpace.write(dataset, to: folder)
        timeFlowsRevision += 1
    }

    func removeTimeFlowPair(_ pair: String) {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard var dataset = SankeySpace.read(from: folder) else { return }
        dataset.series.removeAll { $0.pair == pair }
        dataset.modified = .now
        SankeySpace.write(dataset, to: folder)
        timeFlowsRevision += 1
    }

    /// One of the sample shelf's long-run series, fetched and mirrored.
    func addSampleFlow(_ sample: SankeySpace.SampleFlow) async throws {
        let series = try await SankeySpace.fetchSample(sample)
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var dataset = SankeySpace.read(from: folder)
            ?? SankeySpace.Dataset(series: [], modified: .now)
        dataset.series.removeAll { $0.pair == series.pair }
        dataset.series.append(series)
        dataset.modified = .now
        SankeySpace.write(dataset, to: folder)
        timeFlowsRevision += 1
    }
}

// MARK: - The list

/// Views ▸ Time Flows: every data line standing along the headset's
/// corridor, and the + that asks for more.
struct TimeFlowsListView: View {
    @Environment(AppModel.self) private var model
    @State private var showsRequest = false
    /// The sample being fetched right now, by id — one at a time.
    @State private var fetchingSample: String?
    @State private var sampleError: String?

    var body: some View {
        // The revision read makes this view live to mirror changes.
        let _ = model.timeFlowsRevision
        let pairs = model.timeFlowPairs()
        List {
            if pairs.isEmpty {
                ContentUnavailableView {
                    Label("No Time Flows yet", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("A Time Flow is a data line standing along the headset's timeline — each year one point. Take one from the samples below, or ask for anything with +.")
                }
            }
            ForEach(pairs, id: \.pair) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                        Text(rowDetail(of: entry.series))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.removeTimeFlowPair(entry.pair)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this flow from the corridor")
                }
                .padding(.vertical, 3)
            }
            Section("Samples — the last 150 years") {
                ForEach(SankeySpace.sampleFlows) { sample in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sample.name)
                            Text(sample.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if pairs.contains(where: { $0.pair == sample.id }) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                        } else if fetchingSample == sample.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Add") { addSample(sample) }
                                .buttonStyle(.borderless)
                                .disabled(fetchingSample != nil)
                        }
                    }
                }
                if let sampleError {
                    Label(sampleError, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Time Flows")
        .toolbar {
            Button {
                showsRequest = true
            } label: {
                Label("Add Time Flow", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showsRequest) {
            TimeFlowRequestView { fetched in
                model.addTimeFlows(fetched)
            }
            .environment(model)
        }
    }

    private func addSample(_ sample: SankeySpace.SampleFlow) {
        guard fetchingSample == nil else { return }
        fetchingSample = sample.id
        sampleError = nil
        Task { @MainActor in
            defer { fetchingSample = nil }
            do {
                try await model.addSampleFlow(sample)
            } catch {
                sampleError = error.localizedDescription
            }
        }
    }

    private func rowDetail(of series: [SankeySpace.Series]) -> String {
        let years = series.flatMap { $0.values.map(\.year) }
        let unit = series.first?.unit ?? ""
        guard let first = years.min(), let last = years.max() else { return unit }
        let lines = series.count == 1 ? "one line" : "\(series.count) lines"
        return "\(lines), \(unit.isEmpty ? "values" : unit), \(first)–\(last)"
    }
}

// MARK: - The + dialog

/// Ask for Data, Liquid Information's + dialog brought across: the
/// request interpreted on this device, the data fetched from the real
/// providers, one question asked when the request is vague, and the
/// user's own file parsed the deterministic way. What lands here are
/// fetched series; the caller folds them into the corridor.
struct TimeFlowRequestView: View {
    let onAdd: ([FetchedSeries]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var category: DataCategory = .any
    @State private var isWorking = false
    @State private var status = ""
    @State private var errorMessage: String?

    /// When the model can't route a request, it asks the user one question;
    /// the answer is folded into the prompt and the request retried.
    @State private var followUpQuestion: String?
    @State private var followUpAnswer = ""
    @State private var followUpOptions: [String] = []
    @State private var clarifications = ""
    @State private var clarificationRounds = 0
    /// The range question is asked at most once per conversation; if the
    /// user's answer still leaves it vague, the default proceeds.
    @State private var askedForRange = false
    private static let maximumClarificationRounds = 3

    /// The user's own data file, mid-import — while set, the follow-up
    /// answers feed the file parser instead of the AI.
    @State private var showsFileImporter = false
    @State private var pendingFileText: String?
    @State private var pendingFileName = ""
    @State private var fileChoices = TabularDataImporter.Choices()
    @State private var pendingFileQuestion: TabularDataImporter.QuestionKind?

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Request") {
                    TextField("", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Category", selection: $category) {
                        ForEach(DataCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isWorking)
                }
                Section {
                    Text("The request is interpreted on this device by Apple Intelligence; the data itself is fetched from Open-Meteo (weather), Yahoo Finance (finance), the World Bank (country statistics), and NOAA (solar activity). Each flow lands as one point per year on the headset's timeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let unavailable = SeriesPlanner.unavailabilityReason {
                    Section {
                        Label(unavailable, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if isWorking {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(status)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let followUpQuestion {
                    Section("One question") {
                        Label(followUpQuestion, systemImage: "questionmark.bubble")
                        ForEach(followUpOptions, id: \.self) { option in
                            Button(option) {
                                followUpAnswer = option
                                answerFollowUp()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .disabled(isWorking)
                        }
                        TextField("Your answer", text: $followUpAnswer)
                            .onSubmit { answerFollowUp() }
                        Button("Answer and Retry") { answerFollowUp() }
                            .disabled(followUpAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Time Flow")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Open Data") {
                        showsFileImporter = true
                    }
                    .help("Open your own data file — CSV and similar tables")
                    .disabled(isWorking)
                    Spacer()
                    Button("Fetch") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || trimmedPrompt.isEmpty
                                  || SeriesPlanner.unavailabilityReason != nil)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .fileImporter(isPresented: $showsFileImporter,
                          allowedContentTypes: [.delimitedText, .commaSeparatedText,
                                                .tabSeparatedText, .plainText, .text]) { result in
                if case .success(let url) = result {
                    loadFile(url)
                }
            }
            .onChange(of: prompt) {
                // A new request starts a fresh conversation, abandoning any
                // half-answered file import.
                clarifications = ""
                clarificationRounds = 0
                followUpQuestion = nil
                followUpOptions = []
                askedForRange = false
                pendingFileText = nil
                pendingFileQuestion = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 340)
    }

    private func run() {
        isWorking = true
        errorMessage = nil
        followUpQuestion = nil
        followUpOptions = []
        status = "Interpreting the request\u{2026}"
        let fullRequest = trimmedPrompt + clarifications
        Task {
            do {
                var plan = try await SeriesPlanner.plan(for: fullRequest, category: category)
                // Scene commands are Liquid Information's — here every
                // request is data, so a command the model imagined is
                // simply dropped.
                plan.command = .none

                // No stated range for data without a natural default: ask
                // rather than assume — once.
                let vague = SeriesPlanner.requestsNeedingRange(in: plan, userText: fullRequest)
                if !vague.isEmpty, !askedForRange,
                   clarificationRounds < Self.maximumClarificationRounds {
                    askedForRange = true
                    let subjects = vague.map(\.subject).joined(separator: " and ")
                    followUpQuestion = "What time range should \(subjects) cover?"
                    followUpOptions = ["The last five years", "Since 1960", "Since 1940"]
                    isWorking = false
                    return
                }

                guard !plan.requests.isEmpty else {
                    errorMessage = "Nothing fetchable was found in the request."
                    isWorking = false
                    return
                }
                status = "Fetching \(plan.requests.map(\.subject).joined(separator: ", "))\u{2026}"
                let fetched = try await SeriesPlanner.makeFetched(for: plan)
                onAdd(fetched)
                dismiss()
            } catch where SeriesPlanner.isClarifiable(error)
                && clarificationRounds < Self.maximumClarificationRounds {
                status = "Thinking of a follow-up question\u{2026}"
                if let question = try? await SeriesPlanner.clarifyingQuestion(
                    for: fullRequest, problem: error.localizedDescription) {
                    followUpQuestion = question
                    followUpOptions = []
                } else {
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    /// Folds the user's answer into the request and tries again — into the
    /// file parser's choices when a file import is pending, otherwise into
    /// the AI conversation.
    private func answerFollowUp() {
        let answer = followUpAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, followUpQuestion != nil else { return }
        followUpAnswer = ""
        followUpQuestion = nil
        followUpOptions = []
        if pendingFileText != nil, let questionKind = pendingFileQuestion {
            applyFileAnswer(answer, to: questionKind)
            pendingFileQuestion = nil
            attemptFileImport()
            return
        }
        // Folded in as a parenthetical rather than a Q-and-A transcript —
        // the small model re-plans far more reliably from a direct restatement.
        clarifications += "\n(The user clarified: \(answer))"
        clarificationRounds += 1
        run()
    }

    // MARK: Loading the user's own file

    private func loadFile(_ url: URL) {
        errorMessage = nil
        followUpQuestion = nil
        followUpOptions = []
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            errorMessage = "\u{201C}\(url.lastPathComponent)\u{201D} could not be read as text."
            return
        }
        pendingFileText = text
        pendingFileName = url.deletingPathExtension().lastPathComponent
        fileChoices = TabularDataImporter.Choices()
        attemptFileImport()
    }

    /// Parses the pending file; the result is either flows for the
    /// corridor or one question for the user, exactly like the AI flow.
    private func attemptFileImport() {
        guard let text = pendingFileText else { return }
        do {
            switch try TabularDataImporter.parse(text: text, fileName: pendingFileName,
                                                 choices: fileChoices) {
            case .series(let fetched):
                onAdd(fetched)
                pendingFileText = nil
                dismiss()
            case .question(let question):
                followUpQuestion = question.text
                followUpOptions = question.options
                pendingFileQuestion = question.kind
            }
        } catch {
            errorMessage = error.localizedDescription
            pendingFileText = nil
        }
    }

    /// Maps a follow-up answer onto the parser's choices.
    private func applyFileAnswer(_ answer: String, to kind: TabularDataImporter.QuestionKind) {
        switch kind {
        case .dateColumn:
            fileChoices.dateColumn = answer
        case .dateOrder:
            fileChoices.dayFirst = answer.lowercased().contains("day")
        case .valueColumns:
            let lowered = answer.lowercased()
            fileChoices.valueColumns = lowered.contains("all")
                ? ["*"]
                : answer.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}
#endif
