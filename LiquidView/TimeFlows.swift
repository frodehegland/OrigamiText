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

    /// One floor timeline's standing in the mirror — how many events,
    /// and when it was fetched. Nil where the theme was never fetched.
    func floorTimelineState(_ theme: SankeySpace.FloorTheme)
        -> (events: Int, modified: Date)? {
        guard let folder = index.folderURL else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard let history = SankeySpace.readFloorHistory(theme: theme, from: folder),
              !history.events.isEmpty else { return nil }
        return (history.events.count, history.modified)
    }

    /// Fetches one floor timeline from Wikidata and mirrors it — the
    /// headset reads it on its next scan instead of fetching itself.
    func addFloorTimeline(_ theme: SankeySpace.FloorTheme) async throws {
        let events = try await SankeySpace.fetchFloorHistory(theme: theme)
        guard !events.isEmpty else {
            throw NSError(domain: "OrigamiText", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Wikidata returned no events for \(theme.displayName)."])
        }
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        SankeySpace.writeFloorHistory(
            SankeySpace.FloorHistory(events: events, modified: .now),
            theme: theme, to: folder)
        timeFlowsRevision += 1
    }

    /// Removes one floor timeline's mirror file.
    func removeFloorTimeline(_ theme: SankeySpace.FloorTheme) {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(
            at: folder.appendingPathComponent(theme.fileName))
        timeFlowsRevision += 1
    }

    /// The user's own floor timelines in the mirror, with their standing.
    func userFloorTimelines()
        -> [(slug: String, name: String, events: Int, modified: Date, hasQuery: Bool)] {
        guard let folder = index.folderURL else { return [] }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return SankeySpace.listUserFloorTimelines(in: folder).compactMap { entry in
            guard let history = SankeySpace.readUserFloorHistory(slug: entry.slug,
                                                                 from: folder)
            else { return nil }
            return (entry.slug, entry.name, history.events.count,
                    history.modified, history.query != nil)
        }
    }

    /// A user timeline from the user's own SPARQL — it must bind
    /// ?itemLabel, ?year, and ?links. The query travels in the file,
    /// so Refresh can run it again.
    func addUserFloorTimeline(name: String, query: String) async throws {
        let events = try await SankeySpace.fetchFloorEvents(query: query)
        guard !events.isEmpty else {
            throw NSError(domain: "OrigamiText", code: 1, userInfo: [
                NSLocalizedDescriptionKey: """
                    Wikidata returned no events. The query must SELECT \
                    ?itemLabel, ?year, and ?links.
                    """])
        }
        try writeUserFloorTimeline(name: name, events: events, query: query)
    }

    /// A user timeline from a file: year and title per line (comma or
    /// tab), an optional third column weighting the event.
    func importUserFloorTimeline(name: String, fileURL: URL) throws {
        let secured = fileURL.startAccessingSecurityScopedResource()
        defer { if secured { fileURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "OrigamiText", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "\u{201C}\(fileURL.lastPathComponent)\u{201D} could not be read as text."])
        }
        let events = SankeySpace.parseFloorEvents(text: text)
        guard !events.isEmpty else {
            throw NSError(domain: "OrigamiText", code: 3, userInfo: [
                NSLocalizedDescriptionKey: """
                    No events found. Each line needs a year, then the \
                    event's words \u{2014} comma or tab separated.
                    """])
        }
        try writeUserFloorTimeline(name: name, events: events, query: nil)
    }

    private func writeUserFloorTimeline(name: String, events: [SankeySpace.FloorEvent],
                                        query: String?) throws {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        SankeySpace.writeUserFloorHistory(
            SankeySpace.FloorHistory(events: events, modified: .now,
                                     name: name, query: query),
            slug: SankeySpace.userFloorSlug(name: name), to: folder)
        timeFlowsRevision += 1
    }

    /// Re-runs a user timeline's stored query.
    func refreshUserFloorTimeline(slug: String) async throws {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        let stored = SankeySpace.readUserFloorHistory(slug: slug, from: folder)
        if scoped { folder.stopAccessingSecurityScopedResource() }
        guard let stored, let query = stored.query else { return }
        try await addUserFloorTimeline(name: stored.name ?? slug, query: query)
    }

    func removeUserFloorTimeline(slug: String) {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(
            SankeySpace.userFloorFileName(slug: slug)))
        timeFlowsRevision += 1
    }

    func userFloorQuery(slug: String) -> String? {
        guard let folder = index.folderURL else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return SankeySpace.readUserFloorHistory(slug: slug, from: folder)?.query
    }

    /// The graph's shown name — every series of the pair takes it.
    func renameTimeFlowPair(_ pair: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard var dataset = SankeySpace.read(from: folder) else { return }
        for index in dataset.series.indices where dataset.series[index].pair == pair {
            dataset.series[index].name = trimmed
        }
        dataset.modified = .now
        SankeySpace.write(dataset, to: folder)
        timeFlowsRevision += 1
    }

    /// The graph's chosen ink — every series of the pair wears it; nil
    /// returns the pair to the palette. Carried by the mirror, so the
    /// headset wears it too.
    func setTimeFlowColor(pair: String, hex: String?) {
        guard let folder = index.folderURL else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard var dataset = SankeySpace.read(from: folder) else { return }
        for index in dataset.series.indices where dataset.series[index].pair == pair {
            dataset.series[index].colorHex = hex
        }
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

/// Views ▸ Graphs: every graph standing along the headset's corridor,
/// its colour the reader's to choose, and the + that asks for more.
/// A graph under edit: what the dialog opens on.
struct EditingGraph: Identifiable {
    let pair: String
    let name: String
    let colorHex: String?
    var id: String { pair }
}

struct TimeFlowsListView: View {
    @Environment(AppModel.self) private var model
    @State private var showsRequest = false
    /// The graph whose edit dialog stands open.
    @State private var editingGraph: EditingGraph?
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
                    Label("No graphs yet", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("A graph is a data line standing along the headset's timeline — each year one point. Take one from the samples below, or ask for anything with +.")
                }
            }
            ForEach(pairs, id: \.pair) { entry in
                HStack {
                    // The graph's row opens its edit dialog — the same
                    // dialog that creates one.
                    Button {
                        editingGraph = EditingGraph(
                            pair: entry.pair, name: entry.name,
                            colorHex: entry.series.compactMap(\.colorHex).first)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                            Text(rowDetail(of: entry.series))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    inkMenu(for: entry)
                    Button(role: .destructive) {
                        model.removeTimeFlowPair(entry.pair)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this graph from the corridor")
                }
                .padding(.vertical, 3)
            }
            // The + at the list's foot, beside the toolbar's.
            Button {
                showsRequest = true
            } label: {
                Label("Add Graph", systemImage: "plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
        .navigationTitle("Graphs")
        .toolbar {
            Button {
                showsRequest = true
            } label: {
                Label("Add Graph", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showsRequest) {
            TimeFlowRequestView { fetched in
                model.addTimeFlows(fetched)
            }
            .environment(model)
        }
        .sheet(item: $editingGraph) { graph in
            TimeFlowRequestView(editing: graph) { fetched in
                // A refetch replaces the graph's data.
                model.removeTimeFlowPair(graph.pair)
                model.addTimeFlows(fetched)
            } onEdit: { name, hex in
                model.renameTimeFlowPair(graph.pair, to: name)
                model.setTimeFlowColor(pair: graph.pair, hex: hex)
            }
            .environment(model)
        }
    }

    /// The graph's ink, chosen by pop-up: the corridor palette's named
    /// hues, or Automatic to paint from the palette by pair. The
    /// choice travels through the mirror, so the headset wears it too.
    private func inkMenu(for entry: (pair: String, name: String,
                                     series: [SankeySpace.Series])) -> some View {
        let chosen = entry.series.compactMap(\.colorHex).first
        return Menu {
            Button("Automatic") {
                model.setTimeFlowColor(pair: entry.pair, hex: nil)
            }
            Divider()
            ForEach(SankeySpace.inkChoices, id: \.hex) { choice in
                Button {
                    model.setTimeFlowColor(pair: entry.pair, hex: choice.hex)
                } label: {
                    Label {
                        Text(choice.name)
                    } icon: {
                        Image(systemName: chosen == choice.hex
                            ? "checkmark.circle.fill" : "circle.fill")
                            .foregroundStyle(Color(hexCode: choice.hex) ?? .secondary)
                    }
                }
            }
        } label: {
            Circle()
                .fill(chosen.flatMap { Color(hexCode: $0) } ?? Color.secondary.opacity(0.4))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.quaternary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The graph's colour — Automatic paints from the palette")
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
    /// Editing an existing graph: its identity opens the same dialog
    /// with name and colour on top, and Fetch replacing its data.
    /// Nil creates.
    var editing: EditingGraph? = nil
    let onAdd: ([FetchedSeries]) -> Void
    /// Called by Save when editing: the (possibly changed) name and
    /// colour.
    var onEdit: ((String, String?) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var editedName = ""
    @State private var editedHex: String?
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
                if editing != nil {
                    Section("Graph") {
                        TextField("Name", text: $editedName)
                        Picker("Colour", selection: $editedHex) {
                            Text("Automatic").tag(String?.none)
                            ForEach(SankeySpace.inkChoices, id: \.hex) { choice in
                                Label {
                                    Text(choice.name)
                                } icon: {
                                    Image(systemName: "circle.fill")
                                        .foregroundStyle(Color(hexCode: choice.hex) ?? .secondary)
                                }
                                .tag(String?.some(choice.hex))
                            }
                        }
                    }
                }
                Section(editing == nil ? "Request" : "Refetch the data") {
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
            .navigationTitle(editing == nil ? "Add Graph" : "Edit Graph")
            .onAppear {
                if let editing {
                    editedName = editing.name
                    editedHex = editing.colorHex
                    if prompt.isEmpty { prompt = editing.name }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Open Data") {
                        showsFileImporter = true
                    }
                    .help("Open your own data file — CSV and similar tables")
                    .disabled(isWorking)
                    Spacer()
                    if editing != nil {
                        Button("Save") {
                            onEdit?(editedName, editedHex)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking
                                  || editedName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Fetch") { run() }
                            .disabled(isWorking || trimmedPrompt.isEmpty
                                      || SeriesPlanner.unavailabilityReason != nil)
                    } else {
                        Button("Fetch") { run() }
                            .buttonStyle(.borderedProminent)
                            .disabled(isWorking || trimmedPrompt.isEmpty
                                      || SeriesPlanner.unavailabilityReason != nil)
                    }
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

// MARK: - Timelines

/// A user floor timeline open for editing — same dialog as creation.
struct EditingFloorTimeline: Identifiable {
    let slug: String
    let name: String
    let query: String?
    var id: String { slug }
}

/// Views ▸ Timelines: the histories lying under the headset's corridor
/// — the built-in Wikidata themes and the user's own, with the + that
/// makes one from a query or a file.
struct TimelinesListView: View {
    @Environment(AppModel.self) private var model
    /// The timeline being fetched right now — one at a time.
    @State private var fetchingFloor: SankeySpace.FloorTheme?
    @State private var floorError: String?
    @State private var showsAdd = false
    /// The user timeline whose edit dialog stands open.
    @State private var editingTimeline: EditingFloorTimeline?

    var body: some View {
        // The revision read makes this view live to mirror changes.
        let _ = model.timeFlowsRevision
        List {
            Section("Wikidata themes") {
                ForEach(SankeySpace.FloorTheme.allCases) { theme in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(theme.displayName)
                            Text(floorDetail(of: theme))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if fetchingFloor == theme {
                            ProgressView().controlSize(.small)
                        } else if model.floorTimelineState(theme) != nil {
                            Button("Refresh") { addFloor(theme) }
                                .buttonStyle(.borderless)
                                .disabled(fetchingFloor != nil)
                            Button(role: .destructive) {
                                model.removeFloorTimeline(theme)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this timeline from the mirror")
                        } else {
                            Button("Add") { addFloor(theme) }
                                .buttonStyle(.borderless)
                                .disabled(fetchingFloor != nil)
                        }
                    }
                }
            }
            Section("Your own") {
                let mine = model.userFloorTimelines()
                if mine.isEmpty {
                    Text("A timeline of your own comes from a Wikidata query, or from a file of years and events — add one with +.")
                        .foregroundStyle(.secondary)
                }
                ForEach(mine, id: \.slug) { entry in
                    HStack {
                        Button {
                            editingTimeline = EditingFloorTimeline(
                                slug: entry.slug, name: entry.name,
                                query: model.userFloorQuery(slug: entry.slug))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text("\(entry.events) events, fetched \(entry.modified.formatted(date: .abbreviated, time: .omitted))\(entry.hasQuery ? "" : " \u{00B7} imported file")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if entry.hasQuery {
                            Button("Refresh") { refreshUserFloor(entry.slug) }
                                .buttonStyle(.borderless)
                                .disabled(fetchingFloor != nil)
                        }
                        Button(role: .destructive) {
                            model.removeUserFloorTimeline(slug: entry.slug)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this timeline from the mirror")
                    }
                }
                if let floorError {
                    Label(floorError, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // The + at the list's foot, beside the toolbar's.
                Button {
                    showsAdd = true
                } label: {
                    Label("Add Timeline", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Section {
                Text("Each timeline lies on the floor under the headset's corridor, every event at its year's depth — chosen there with the Floor Timeline chip or the Time Data dialog. The Wikidata themes rank events by how many Wikipedias carry them; fetched here, they are ready before the headset asks.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("Timelines")
        .toolbar {
            Button {
                showsAdd = true
            } label: {
                Label("Add Timeline", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showsAdd) {
            FloorTimelineAddView()
                .environment(model)
        }
        .sheet(item: $editingTimeline) { timeline in
            FloorTimelineAddView(editing: timeline)
                .environment(model)
        }
    }

    private func addFloor(_ theme: SankeySpace.FloorTheme) {
        guard fetchingFloor == nil else { return }
        fetchingFloor = theme
        floorError = nil
        Task { @MainActor in
            defer { fetchingFloor = nil }
            do {
                try await model.addFloorTimeline(theme)
            } catch {
                floorError = error.localizedDescription
            }
        }
    }

    private func refreshUserFloor(_ slug: String) {
        floorError = nil
        Task { @MainActor in
            do {
                try await model.refreshUserFloorTimeline(slug: slug)
            } catch {
                floorError = error.localizedDescription
            }
        }
    }

    private func floorDetail(of theme: SankeySpace.FloorTheme) -> String {
        guard let state = model.floorTimelineState(theme) else { return "Not fetched" }
        let day = state.modified.formatted(date: .abbreviated, time: .omitted)
        return "\(state.events) events, fetched \(day)"
    }
}

// MARK: - Add Floor Timeline

/// A user's own floor timeline: named, then either a Wikidata SPARQL
/// query (which must bind ?itemLabel, ?year, and ?links — the built-in
/// themes' shape) or the user's own file of years and events.
struct FloorTimelineAddView: View {
    var editing: EditingFloorTimeline? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var query: String
    /// The plain-words ask, drafted into SPARQL on request.
    @State private var plainWords = ""
    @State private var draftNote: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsFileImporter = false

    init(editing: EditingFloorTimeline? = nil) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _query = State(initialValue: editing?.query ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    // Bare and left-aligned: a grouped form pushes a
                    // field's text to the trailing edge otherwise.
                    TextField("", text: $name)
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    HStack {
                        TextField("", text: $plainWords, prompt:
                            Text("iphone \u{00B7} telescopes \u{00B7} volcanic eruptions"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .onSubmit { draft() }
                        Button("Draft Query") { draft() }
                            .disabled(isWorking
                                      || plainWords.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Ask in plain words")
                } footer: {
                    Text("The words are looked up on Wikidata and a query drafted around what they name — it lands below for you to run and adapt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $query)
                        .font(.system(size: 12, design: .monospaced))
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 140)
                } header: {
                    Text("Wikidata query")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("""
                            SPARQL against query.wikidata.org, binding ?itemLabel, \
                            ?year, and ?links — the shape the built-in themes use. \
                            Or skip the query and import your own file below: one \
                            event per line, the year then the words, comma or tab \
                            separated, an optional third column weighting it.
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Insert a working example (video games)") {
                            if trimmedName.isEmpty { name = "Video Game History" }
                            query = Self.exampleQuery
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                if isWorking {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Asking Wikidata\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let draftNote {
                    Section {
                        Label(draftNote, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
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
            .navigationTitle(editing == nil ? "Add Floor Timeline" : "Edit Floor Timeline")
            .safeAreaInset(edge: .bottom) {
                // Live as soon as there is something to act on — a
                // missing name is said in words, never a dead button.
                HStack {
                    Button("Import File\u{2026}") {
                        guard named() else { return }
                        showsFileImporter = true
                    }
                    .disabled(isWorking)
                    .help("Your own timeline: a year and an event per line")
                    Spacer()
                    Button("Fetch") { fetch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking
                                  || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .fileImporter(isPresented: $showsFileImporter,
                          allowedContentTypes: [.commaSeparatedText, .tabSeparatedText,
                                                .delimitedText, .plainText, .text]) { result in
                if case .success(let url) = result { importFile(url) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    /// A known-good query to start from — verified live (2026-08-25):
    /// notable video games at their release years.
    private static let exampleQuery = """
        SELECT ?itemLabel (YEAR(?date) AS ?year) ?links WHERE {
          ?item wdt:P31 wd:Q7889; wdt:P577 ?date; wikibase:sitelinks ?links.
          FILTER(?links > 60)
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
        } ORDER BY DESC(?links) LIMIT 100
        """

    /// True with a name in place; otherwise says what is missing.
    private func named() -> Bool {
        if trimmedName.isEmpty {
            errorMessage = "Give the timeline a name first."
            return false
        }
        return true
    }

    /// Plain words to a drafted query: Wikidata resolves the entity,
    /// the gathering relations are tried in turn, and the winning
    /// SPARQL lands in the editor — visible, runnable, adaptable.
    private func draft() {
        let words = plainWords.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        draftNote = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let drafted = try await SankeySpace.draftFloorQuery(about: words)
                query = drafted.query
                if trimmedName.isEmpty { name = drafted.name }
                draftNote = "Drafted \u{201C}\(drafted.name)\u{201D} — \(drafted.events) events found. Press Fetch to add it."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func fetch() {
        guard named() else { return }
        isWorking = true
        errorMessage = nil
        draftNote = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                if let slug = editing?.slug {
                    model.removeUserFloorTimeline(slug: slug)
                }
                try await model.addUserFloorTimeline(name: trimmedName, query: query)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importFile(_ url: URL) {
        guard named() else { return }
        errorMessage = nil
        do {
            if let slug = editing?.slug {
                model.removeUserFloorTimeline(slug: slug)
            }
            try model.importUserFloorTimeline(name: trimmedName, fileURL: url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
