import SwiftUI
import FoundationModels

// MARK: - The bot

/// A bot: a well-known person, living or dead, standing in the library
/// as a reader. Created by typing a name; the on-device model works out
/// who is meant, and what it knows of them travels into every judgement
/// the bot later makes.
nonisolated struct Bot: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// The person's name as usually written — "Doug Engelbart".
    var name: String
    /// Their years — "1925–2013", or "born 1962" while living.
    var years: String = ""
    /// Who they are, in a sentence or two, from the identification.
    var summary: String = ""
    var created: Date = .now

    /// The bot's title: the name with "bot" appended, so the stand-in is
    /// never mistaken for the person — "Doug Engelbart bot".
    var displayName: String { "\(name) bot" }
}

/// One bot's judgement of one document: whether the person would agree,
/// and why, in their voice.
nonisolated struct BotStance: Codable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case agree, disagree, neutral
    }
    var verdict: Verdict
    var reason: String
}

// MARK: - What the model returns

/// The identification as the on-device model returns it: who a typed
/// name most likely means.
@Generable
nonisolated struct GeneratedBotIdentification {
    @Guide(description: "True only when the name clearly means one well-known person")
    var isConfident: Bool
    @Guide(description: "The real people this name most likely refers to, most likely first — exactly one when confident, up to five when not, none when no known person matches", .maximumCount(5))
    var candidates: [GeneratedBotCandidate]
}

@Generable
nonisolated struct GeneratedBotCandidate {
    @Guide(description: "The person's full name as usually written")
    var name: String
    @Guide(description: "Their years, e.g. \"1925–2013\", or \"born 1962\" if living")
    var years: String
    @Guide(description: "One or two sentences on who this person is and what they are known for")
    var summary: String
}

/// One judgement as the model returns it.
@Generable
nonisolated struct GeneratedBotStance {
    @Guide(description: "Whether the person would agree with the document's position", .anyOf(["agree", "disagree", "neutral"]))
    var verdict: String
    @Guide(description: "Why, in one or two sentences, in the person's own voice")
    var reason: String
}

/// Defaults for bots. Everything runs on-device (Apple Intelligence);
/// no text leaves the Mac. The on-device model's knowledge of public
/// figures is real but shallow — the candidate picker exists so the
/// reader, not the model, has the last word on who is meant.
nonisolated enum Bots {

    static let identificationPrompt = """
    A reader typed a name to create a bot standing in for a real, well-known person, living or dead. From general knowledge, work out who the name means. When one well-known person is the clear match, be confident and return exactly that one. When several known people share the name, or the match is unclear, return up to five, most likely first. Only real people you actually know of — when the name matches no one, return no candidates and no confidence. For each candidate give the full name as usually written, their years, and one or two sentences on who they are and what they are known for.
    """

    static let stancePrompt = """
    You speak for a well-known person as a bot bearing their name. From what is publicly known of their work, writing, and stated views, read the document below and judge whether the person would agree with its position, disagree, or stand neutral — neutral when the document lies outside what their known views can honestly answer. Give the verdict, then the reason: one or two sentences in the person's own voice, grounded in their known positions, never invented biography. The document begins with a == line giving its title, author, date, and address; anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata, never content.
    """

    static let questionPrompt = """
    You speak for a well-known person as a bot bearing their name. From what is publicly known of their work, writing, and stated views, answer the reader's question about the library of documents below, in the person's own voice — concise and concrete, naming documents by their titles when they matter. Each document begins with a == line giving its title, author, date, and address. Claim nothing about the person's life that is not publicly known.
    """

    /// The pre-written questions offered on ctrl-click, before "Ask…".
    static let presetQuestions = [
        "What is of value here?",
        "What do you have issues with?",
    ]

    /// Caps keep each request inside the on-device model's window; long
    /// documents contribute their opening.
    static let perDocumentCharacterLimit = 1_500
    static let questionPerDocumentCharacterLimit = 500
    static let questionCorpusCharacterLimit = 8_000
}

// MARK: - The store

/// The shelf of bots and everything they have judged: plain JSON in the
/// app container, like the person directory. Stances are cached per bot
/// per document, so a bot re-reads only what it has not yet seen.
@MainActor @Observable
final class BotStore {
    private(set) var bots: [Bot] = []
    /// Each bot's judgements, by bot id (as a string, for readable JSON)
    /// then document id.
    private(set) var stances: [String: [String: BotStance]] = [:]
    /// The bot now reading, with its progress, or nil while idle.
    private(set) var analysis: (botID: UUID, done: Int, total: Int)?

    private var analysisTask: Task<Void, Never>?
    private let botsURL: URL
    private let stancesURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        botsURL = base.appendingPathComponent("Bots.json")
        stancesURL = base.appendingPathComponent("BotStances.json")
        load()
    }

    func bot(id: UUID) -> Bot? {
        bots.first { $0.id == id }
    }

    func add(_ bot: Bot) {
        bots.append(bot)
        saveBots()
    }

    func remove(_ bot: Bot) {
        if analysis?.botID == bot.id { cancelAnalysis() }
        bots.removeAll { $0.id == bot.id }
        stances[bot.id.uuidString] = nil
        saveBots()
        saveStances()
    }

    func stance(botID: UUID, docID: String) -> BotStance? {
        stances[botID.uuidString]?[docID]
    }

    /// Forgetting is always available: the bot's judgements are discarded
    /// and the next reading starts afresh.
    func clearStances(for bot: Bot) {
        if analysis?.botID == bot.id { cancelAnalysis() }
        stances[bot.id.uuidString] = nil
        saveStances()
    }

    // MARK: Identification

    /// Asks the on-device model who a typed name means. Confidence means
    /// the first (and only) candidate is a near-certain match.
    nonisolated static func identify(name: String) async throws -> GeneratedBotIdentification {
        let prompt = Bots.identificationPrompt + "\n\nTHE TYPED NAME: \(name)\n"
        let session = LanguageModelSession()
        return try await session.respond(to: prompt, generating: GeneratedBotIdentification.self).content
    }

    // MARK: Reading the library

    /// One bot reads the library: every document its judgements do not
    /// yet cover goes to the on-device model with the bot's persona, and
    /// each verdict lands — and is saved — as it arrives. A new call,
    /// same bot or another, replaces the reading in progress.
    func analyze(_ bot: Bot, documents: [LiquidDoc]) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        cancelAnalysis()
        let pending = documents.filter { stance(botID: bot.id, docID: $0.id) == nil }
        guard !pending.isEmpty else { return }
        analysis = (bot.id, 0, pending.count)
        analysisTask = Task {
            for (index, doc) in pending.enumerated() {
                guard !Task.isCancelled else { return }
                await judge(doc, as: bot)
                if analysis?.botID == bot.id {
                    analysis = (bot.id, index + 1, pending.count)
                }
            }
            if analysis?.botID == bot.id { analysis = nil }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysis = nil
    }

    /// One document to one bot: the persona and the document's opening go
    /// to the model; the verdict and its reason come back. On any error
    /// the document stays unjudged and the next reading tries again.
    private func judge(_ doc: LiquidDoc, as bot: Bot) async {
        var prompt = Bots.stancePrompt
        prompt += "\n\nTHE PERSON: \(bot.name)"
        if !bot.years.isEmpty { prompt += " (\(bot.years))" }
        if !bot.summary.isEmpty { prompt += "\n\(bot.summary)" }
        prompt += "\n\nTHE DOCUMENT:\n\(Self.digest(of: doc, limit: Bots.perDocumentCharacterLimit))"
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: GeneratedBotStance.self)
            guard !Task.isCancelled else { return }
            let verdict = BotStance.Verdict(rawValue: response.content.verdict) ?? .neutral
            stances[bot.id.uuidString, default: [:]][doc.id] =
                BotStance(verdict: verdict, reason: response.content.reason)
            saveStances()
        } catch {
            // Left unjudged; a later reading tries again.
        }
    }

    // MARK: Questions

    /// One question to one bot over the whole visible library — the
    /// pre-written prompts and the reader's own typed question both come
    /// through here. The answer arrives in the person's voice.
    nonisolated static func ask(_ question: String, of bot: Bot,
                                documents: [LiquidDoc]) async throws -> String {
        var prompt = Bots.questionPrompt
        prompt += "\n\nTHE PERSON: \(bot.name)"
        if !bot.years.isEmpty { prompt += " (\(bot.years))" }
        if !bot.summary.isEmpty { prompt += "\n\(bot.summary)" }
        prompt += "\n\nTHE LIBRARY:\n\n"
        var budget = Bots.questionCorpusCharacterLimit
        for doc in documents {
            guard budget > 0 else { break }
            let digest = digest(of: doc, limit: min(Bots.questionPerDocumentCharacterLimit, budget))
            budget -= digest.count
            prompt += digest + "\n\n"
        }
        prompt += "THE QUESTION: \(question)\n"
        let session = LanguageModelSession()
        return try await session.respond(to: prompt).content
    }

    /// A document as a bot reads it: a == line of title, author, date,
    /// and address, then the opening of the text — the Visual-Meta
    /// appendix is metadata, never evidence.
    nonisolated static func digest(of doc: LiquidDoc, limit: Int) -> String {
        let appendixIDs = doc.visualMetaParagraphIDs
        let text = (doc.body ?? [])
            .filter { !appendixIDs.contains($0.id) && !$0.displayText.isEmpty }
            .map(\.displayText)
            .joined(separator: "\n")
        return "== \(doc.title) — \(doc.displayAuthor), "
            + "\(doc.listedDate.formatted(date: .abbreviated, time: .omitted)) [\(doc.id)]\n"
            + String(text.prefix(limit))
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: botsURL),
           let loaded = try? JSONDecoder().decode([Bot].self, from: data) {
            bots = loaded
        }
        if let data = try? Data(contentsOf: stancesURL),
           let loaded = try? JSONDecoder().decode([String: [String: BotStance]].self, from: data) {
            stances = loaded
        }
    }

    private func saveBots() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bots) {
            try? data.write(to: botsURL, options: .atomic)
        }
    }

    private func saveStances() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stances) {
            try? data.write(to: stancesURL, options: .atomic)
        }
    }
}

// MARK: - The view

/// Bots: famous people, living or dead, standing in the library as
/// readers. Type a name and press Return; the on-device model says who
/// it thinks is meant — confirm the one, or choose among up to five —
/// and the bot joins the shelf. Click a bot and it reads every document:
/// green borders where the person would agree, red where they would
/// disagree, and resting the pointer on a card shows why, in their
/// voice. Cards drag freely; faint threads carry the document links.
/// Ctrl-click a bot to put a question to it — pre-written or your own.
struct BotsView: View {
    @Environment(AppModel.self) private var model
    @State private var newBotName = ""
    @State private var isIdentifying = false
    @State private var identification: BotIdentificationResult?
    @State private var selectedBotID: UUID?
    /// Where each document card sits; seeded as a grid, then the
    /// reader's to rearrange.
    @State private var positions: [String: CGPoint] = [:]
    @State private var dragStart: [String: CGPoint] = [:]
    /// The card whose judgement is on display; set by hover, kept until
    /// another card takes over or the background is clicked.
    @State private var hoveredDocID: String?
    /// The bot a typed question is being composed for.
    @State private var askingBot: Bot?
    @State private var typedQuestion = ""
    /// The question on the table and, once the model answers, the answer.
    @State private var exchange: BotExchange?

    /// The model's candidates for a typed name, awaiting the reader's
    /// choice.
    private struct BotIdentificationResult: Identifiable {
        let id = UUID()
        let typedName: String
        let isConfident: Bool
        let candidates: [GeneratedBotCandidate]
    }

    /// One question put to one bot, and the answer as it arrives.
    private struct BotExchange: Identifiable {
        let id = UUID()
        let bot: Bot
        let question: String
        var answer: String?
    }

    private var selectedBot: Bot? {
        selectedBotID.flatMap { model.bots.bot(id: $0) }
    }

    private var visibleDocs: [LiquidDoc] {
        model.filteredEntries.map(\.doc)
    }

    var body: some View {
        VStack(spacing: 0) {
            botShelf
            Divider()
            content
        }
        .overlay(alignment: .top) {
            if let exchange {
                answerPanel(exchange)
            }
        }
        .sheet(item: $identification) { identificationSheet($0) }
        .sheet(item: $askingBot) { questionSheet(for: $0) }
    }

    // MARK: The shelf

    private var botShelf: some View {
        HStack(spacing: 12) {
            TextField("New bot: type a name, press Return", text: $newBotName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(identifyTypedName)
                .disabled(isIdentifying)
            if isIdentifying {
                ProgressView()
                    .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.bots.bots) { bot in
                        botChip(bot)
                    }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }

    private func botChip(_ bot: Bot) -> some View {
        let isSelected = bot.id == selectedBotID
        return Button {
            select(bot)
        } label: {
            VStack(spacing: 3) {
                PersonAvatarView(name: bot.name, size: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 40 * 0.18, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    )
                Text(bot.displayName)
                    .font(.caption2)
                    .fontWeight(isSelected ? .bold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: 110)
            }
        }
        .buttonStyle(.plain)
        .help(bot.summary.isEmpty ? bot.displayName : "\(bot.name) (\(bot.years)) — \(bot.summary)")
        .contextMenu {
            ForEach(Bots.presetQuestions, id: \.self) { question in
                Button(question) { ask(question, of: bot) }
            }
            Button("Ask \(bot.displayName)…") {
                typedQuestion = ""
                askingBot = bot
            }
            Divider()
            Button("Read the Library Again") {
                model.bots.clearStances(for: bot)
                select(bot)
            }
            Divider()
            Button("Delete Bot", role: .destructive) {
                if selectedBotID == bot.id { selectedBotID = nil }
                model.bots.remove(bot)
            }
        }
    }

    // MARK: The space

    @ViewBuilder
    private var content: some View {
        if let bot = selectedBot {
            space(for: bot)
        } else if model.bots.bots.isEmpty {
            ContentUnavailableView(
                "No Bots",
                systemImage: "brain.head.profile",
                description: Text("Type a name above and press Return — the bot stands in for that person and reads the library as them."))
        } else {
            ContentUnavailableView(
                "Choose a Bot",
                systemImage: "brain.head.profile",
                description: Text("Click a bot above and it reads every document: green where the person would agree, red where they would disagree."))
        }
    }

    private func space(for bot: Bot) -> some View {
        GeometryReader { geometry in
            ZStack {
                linkThreads(in: geometry.size)
                ForEach(visibleDocs) { doc in
                    card(for: doc, bot: bot)
                        .position(positions[doc.id]
                                  ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
                        .gesture(drag(for: doc.id))
                }
                if visibleDocs.isEmpty {
                    ContentUnavailableView(
                        "No Documents",
                        systemImage: "brain.head.profile",
                        description: Text("Add documents to the community folder and the bot will read them."))
                }
                if let doc = hoveredDoc,
                   let stance = model.bots.stance(botID: bot.id, docID: doc.id) {
                    stancePanel(doc: doc, stance: stance, bot: bot, in: geometry.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { hoveredDocID = nil }
            .onAppear { seedPositions(in: geometry.size) }
            .onChange(of: visibleDocs.map(\.id)) { seedPositions(in: geometry.size) }
        }
        .overlay(alignment: .bottom) { legend(for: bot) }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hoveredDoc: LiquidDoc? {
        visibleDocs.first { $0.id == hoveredDocID }
    }

    private func card(for doc: LiquidDoc, bot: Bot) -> some View {
        let stance = model.bots.stance(botID: bot.id, docID: doc.id)
        return VStack(spacing: 2) {
            Text(doc.title)
                .font(.system(size: 12, design: .serif))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(doc.displayAuthor)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 150)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor(for: stance), lineWidth: stance == nil ? 1 : 2)
        )
        .opacity(stance == nil ? 0.7 : 1)
        .onHover { inside in
            // Set on entry, kept on exit: the panel must survive the
            // pointer's journey between cards.
            if inside { hoveredDocID = doc.id }
        }
        .onTapGesture(count: 2) { model.openInLibrary(doc) }
        .help(stance == nil
              ? "\(bot.displayName) has not judged this yet"
              : "Hover shows why · double-click to read")
    }

    private func borderColor(for stance: BotStance?) -> Color {
        switch stance?.verdict {
        case .agree: .green
        case .disagree: .red
        case .neutral: Color.secondary.opacity(0.5)
        case nil: Color.secondary.opacity(0.25)
        }
    }

    /// The window behind a hover: the bot's verdict on this document,
    /// and why, in the person's voice. It stays until another card is
    /// hovered or the background is clicked.
    private func stancePanel(doc: LiquidDoc, stance: BotStance, bot: Bot,
                             in size: CGSize) -> some View {
        let anchor = positions[doc.id] ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let verdictLine = switch stance.verdict {
        case .agree: "\(bot.displayName) would agree"
        case .disagree: "\(bot.displayName) would disagree"
        case .neutral: "\(bot.displayName) is neutral"
        }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle()
                    .fill(borderColor(for: stance))
                    .frame(width: 8, height: 8)
                Text(verdictLine)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    hoveredDocID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            Text(doc.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(stance.reason)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .position(x: min(max(anchor.x, 160), size.width - 160),
                  y: max(anchor.y - 80, 70))
    }

    private func legend(for bot: Bot) -> some View {
        HStack(spacing: 12) {
            if let analysis = model.bots.analysis, analysis.botID == bot.id {
                ProgressView()
                    .controlSize(.small)
                Text("\(bot.displayName) is reading — \(analysis.done) of \(analysis.total)")
            } else {
                swatch(.green, "would agree")
                swatch(.red, "would disagree")
                swatch(Color.secondary.opacity(0.5), "neutral")
            }
            Text("hover for why · double-click to read · ctrl-click the bot to ask")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 10)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(color, lineWidth: 2)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    // MARK: Layout and movement

    /// First arrangement: a centered grid, list order — then every card
    /// is the reader's to drag.
    private func seedPositions(in size: CGSize) {
        let docs = visibleDocs
        guard !docs.isEmpty else { return }
        let columns = max(1, Int(Double(docs.count).squareRoot().rounded(.up)))
        let spacing = CGSize(width: 180, height: 90)
        let rows = (docs.count + columns - 1) / columns
        let origin = CGPoint(x: size.width / 2 - Double(columns - 1) * spacing.width / 2,
                             y: size.height / 2 - Double(rows - 1) * spacing.height / 2)
        for (index, doc) in docs.enumerated() where positions[doc.id] == nil {
            positions[doc.id] = CGPoint(x: origin.x + Double(index % columns) * spacing.width,
                                        y: origin.y + Double(index / columns) * spacing.height)
        }
    }

    private func drag(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart[id] ?? positions[id] ?? .zero
                if dragStart[id] == nil { dragStart[id] = start }
                positions[id] = CGPoint(x: start.x + value.translation.width,
                                        y: start.y + value.translation.height)
            }
            .onEnded { _ in dragStart[id] = nil }
    }

    /// Document links as faint threads under the cards — the space stays
    /// a knowledge graph while the borders carry the bot's judgement.
    private func linkThreads(in size: CGSize) -> some View {
        Canvas { context, _ in
            let docs = visibleDocs
            let ids = Set(docs.map(\.id))
            for doc in docs {
                for link in doc.links {
                    let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                    guard ids.contains(target), target != doc.id,
                          let a = positions[doc.id], let b = positions[target] else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Creating a bot

    private func identifyTypedName() {
        let name = newBotName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard case .available = SystemLanguageModel.default.availability else {
            model.showNote("Bots need Apple Intelligence, which is not available on this Mac.")
            return
        }
        isIdentifying = true
        Task {
            defer { isIdentifying = false }
            do {
                let result = try await BotStore.identify(name: name)
                if result.candidates.isEmpty {
                    model.showNote("No known person matched “\(name)”.")
                } else {
                    identification = BotIdentificationResult(typedName: name,
                                                             isConfident: result.isConfident,
                                                             candidates: result.candidates)
                }
            } catch {
                model.showNote("Could not identify “\(name)”: \(error.localizedDescription)")
            }
        }
    }

    private func identificationSheet(_ result: BotIdentificationResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.isConfident
                 ? "Is this who you mean?"
                 : "Who do you mean by “\(result.typedName)”?")
                .font(.headline)
            ForEach(Array(result.candidates.enumerated()), id: \.offset) { _, candidate in
                Button {
                    create(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(candidate.name)
                                .fontWeight(.semibold)
                            Text(candidate.years)
                                .foregroundStyle(.secondary)
                        }
                        Text(candidate.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(result.isConfident
                 ? "Click the person to create “\(result.candidates.first.map(\.name) ?? result.typedName) bot”, or cancel."
                 : "Click a person to create their bot, or cancel.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { identification = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func create(_ candidate: GeneratedBotCandidate) {
        let bot = Bot(name: candidate.name, years: candidate.years, summary: candidate.summary)
        model.bots.add(bot)
        identification = nil
        newBotName = ""
        select(bot)
    }

    // MARK: Selecting and asking

    private func select(_ bot: Bot) {
        selectedBotID = bot.id
        hoveredDocID = nil
        let docs = visibleDocs
        guard docs.contains(where: { model.bots.stance(botID: bot.id, docID: $0.id) == nil }) else { return }
        guard case .available = SystemLanguageModel.default.availability else {
            model.showNote("Bots need Apple Intelligence, which is not available on this Mac.")
            return
        }
        model.bots.analyze(bot, documents: docs)
    }

    private func ask(_ question: String, of bot: Bot) {
        guard case .available = SystemLanguageModel.default.availability else {
            model.showNote("Bots need Apple Intelligence, which is not available on this Mac.")
            return
        }
        let pending = BotExchange(bot: bot, question: question)
        exchange = pending
        let docs = visibleDocs
        Task {
            let answer: String
            do {
                answer = try await BotStore.ask(question, of: bot, documents: docs)
            } catch {
                answer = "The model could not answer: \(error.localizedDescription)"
            }
            if exchange?.id == pending.id {
                exchange?.answer = answer
            }
        }
    }

    private func questionSheet(for bot: Bot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask \(bot.displayName)")
                .font(.headline)
            TextField("Your question", text: $typedQuestion)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitTypedQuestion(to: bot) }
            HStack {
                Spacer()
                Button("Cancel") { askingBot = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Ask") { submitTypedQuestion(to: bot) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func submitTypedQuestion(to bot: Bot) {
        let question = typedQuestion.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        askingBot = nil
        ask(question, of: bot)
    }

    /// The question on the table and its answer, floating over the space
    /// until dismissed.
    private func answerPanel(_ exchange: BotExchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(exchange.bot.displayName) — \(exchange.question)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Button {
                    self.exchange = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            if let answer = exchange.answer {
                ScrollView {
                    Text(answer)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Thinking…")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 5)
        .padding(.top, 12)
    }
}

extension BotsView {
    /// Bots as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "bots",
        name: "Bots",
        systemImage: "brain.head.profile",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(BotsView()) },
        hidesDocumentList: true
    )
}
