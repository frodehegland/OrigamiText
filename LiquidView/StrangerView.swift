import SwiftUI
import FoundationModels

/// The Stranger — after Georg Simmel's stranger, by way of David Millard:
/// an AI reader standing both inside and outside the community, near
/// enough to understand its documents, distant enough to owe their
/// conclusions nothing. Where the bots stand in for known people, the
/// Stranger belongs to no one — its worth is exactly that it does not
/// flatter. Runs entirely on-device (Apple Intelligence); no text leaves
/// the Mac. Both prompts are editable in Settings → AI.
nonisolated enum Stranger {

    /// How the corpus reads, shared by both modes — the same schooling
    /// the other AI views give.
    static let readingInstructions = """
    How to read the material: each document begins with a == line giving its title, author, date, and address. A following Relations: line is metadata — typed links between documents (cites, responds-to, extends, supports, questions, disagrees-with, revises) — treat it as structure, never as prose. Anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata about a document, not content; disregard it as text even if fragments appear.
    """

    static let defaultChallengePrompt = """
    You are the Stranger: a reader who stands both inside and outside this community of thinkers — close enough to understand their documents, distant enough to owe their conclusions nothing. You never flatter and are never rude; your challenge is a form of respect. You are in CHALLENGE mode: find what this community believes together but has never had to defend, and make the strongest honest case against it from outside their frame.

    \(readingInstructions) Support without any disagreement is a sign of unexamined consensus.

    Name up to five findings, the most settled consensus first. Each needs: a topic of one to four words; the community's shared position in one sentence; the addresses of the documents holding it, copied exactly from their == lines; and your answer — two or three sentences making the strongest honest case against the position, drawing on perspectives the documents never consider. Then name the one question the community keeps writing around but never asks. If the community already argues well with itself, say less — an empty list is an honest answer. Never invent an address.

    Finally, judge whether the reader would now be better served by your SUPPORT mode — what the community has right but undervalues. Suggest the switch only when you mean it, with your reason in one sentence addressed to the reader; the reader decides.
    """

    static let defaultSupportPrompt = """
    You are the Stranger: a reader who stands both inside and outside this community of thinkers — close enough to understand their documents, distant enough to owe their conclusions nothing. Your support carries weight precisely because you never flatter. You are in SUPPORT mode: find what this community has genuinely right but undervalues, overlooks, or has left standing alone.

    \(readingInstructions)

    Name up to five findings, the most undervalued first. Each needs: a topic of one to four words; the position or contribution in one sentence, as the documents hold it; the addresses of the documents holding it, copied exactly from their == lines; and your answer — two or three sentences on why it deserves more weight than the community gives it, seen from outside their frame. Then name the one question the community is closer to answering than it realizes. If nothing is genuinely undervalued, say less — an empty list is an honest answer. Never invent an address.

    Finally, judge whether the reader would now be better served by your CHALLENGE mode — what the community believes together but has never defended. Suggest the switch only when you mean it, with your reason in one sentence addressed to the reader; the reader decides.
    """
}

/// One finding as the model returns it. The same shape serves both modes:
/// the prompt decides whether the answer challenges or supports.
@Generable
nonisolated struct GeneratedStrangerFinding {
    @Guide(description: "The matter at hand: one to four words")
    var topic: String
    @Guide(description: "The position in one sentence, as the documents hold it")
    var position: String
    @Guide(description: "Addresses of the documents holding the position, copied exactly from the == lines, e.g. f.hegla.093000k")
    var addresses: [String]
    @Guide(description: "The stranger's answer in two or three sentences, from outside the community's frame")
    var answer: String
}

@Generable
nonisolated struct GeneratedStrangerReading {
    @Guide(description: "The findings, most important first; empty if the library gives the stranger nothing honest to say", .maximumCount(5))
    var findings: [GeneratedStrangerFinding]
    @Guide(description: "The stranger's one question to the community, as a single question")
    var question: String
    @Guide(description: "True only when the stranger genuinely believes the reader would now be better served by the other mode")
    var suggestsOtherMode: Bool
    @Guide(description: "When suggesting the other mode: why, in one sentence addressed to the reader")
    var modeSwitchReason: String
}

/// The Stranger's view: choose a mode — Challenge or Support — and summon
/// it. The reading arrives grounded: every address is verified against
/// the index, and a finding without real documents is dropped. The
/// Stranger may ask to switch modes, but never switches itself — the
/// reader confirms or declines. A reading worth keeping can be put on
/// the record as an ordinary document in the community folder, its
/// machine authorship declared.
struct StrangerView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.aiStrangerChallengePromptKey) private var challengePrompt = Stranger.defaultChallengePrompt
    @AppStorage(AppSettings.aiStrangerSupportPromptKey) private var supportPrompt = Stranger.defaultSupportPrompt
    @State private var mode: StrangerMode = .challenge
    @State private var reading: StrangerReading?
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var unfurled: Set<String> = []

    enum StrangerMode: String, CaseIterable, Identifiable {
        case challenge = "Challenge"
        case support = "Support"
        var id: String { rawValue }
        var other: StrangerMode { self == .challenge ? .support : .challenge }
        /// How the record document links the documents a finding names: a
        /// challenge questions them, support supports them.
        var recordRel: String { self == .challenge ? "questions" : "supports" }
    }

    /// A finding whose addresses survived grounding.
    struct ResolvedFinding: Identifiable {
        let topic: String
        let position: String
        let answer: String
        let entries: [IndexEntry]
        var id: String { topic }
    }

    /// One completed reading, kept whole so the record and the
    /// mode-switch request always describe the reading on screen.
    struct StrangerReading {
        let mode: StrangerMode
        let findings: [ResolvedFinding]
        let question: String
        /// The Stranger's request to switch modes, when it made one —
        /// granted only by the reader.
        let modeRequest: String?
    }

    var body: some View {
        Group {
            switch SystemLanguageModel.default.availability {
            case .available:
                content
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Apple Intelligence Unavailable", systemImage: "person.fill.questionmark")
                } description: {
                    Text("The Stranger uses the on-device model, so no text leaves this Mac. \(describe(reason))")
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        run()
                    } label: {
                        Label(isRunning ? "Reading…" : "Summon the Stranger",
                              systemImage: "person.fill.questionmark")
                    }
                    .disabled(isRunning)
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Picker("Mode", selection: $mode) {
                        ForEach(StrangerMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .help("Challenge names what the community believes but has never defended; Support names what it has right but undervalues")
                    Spacer()
                    if let reading, !reading.findings.isEmpty {
                        Button {
                            putOnRecord(reading)
                        } label: {
                            Label("Put It on the Record", systemImage: "signature")
                        }
                        .help("Writes this reading into the community folder as a document — machine authorship declared, its claims linked to the documents they answer")
                    }
                }
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if reading == nil, !isRunning {
                    Text("The Stranger stands both inside and outside the community — after Georg Simmel's stranger, by way of David Millard. It reads every document, but owes the community's conclusions nothing: in Challenge it names what everyone believes but no one has defended; in Support, what is right but undervalued. It may ask to switch modes; only you can grant it. The prompts are yours: Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let reading {
                    if reading.findings.isEmpty, !isRunning {
                        Text(reading.mode == .challenge
                             ? "The Stranger found no consensus worth challenging — this community already argues well with itself. An empty answer is an honest one."
                             : "The Stranger found nothing genuinely undervalued. An empty answer is an honest one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(reading.findings) { finding in
                        findingRow(finding, mode: reading.mode)
                    }
                    if !reading.question.isEmpty {
                        questionView(reading.question, mode: reading.mode)
                    }
                    if let request = reading.modeRequest {
                        modeRequestView(request, from: reading.mode)
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    @ViewBuilder
    private func findingRow(_ finding: ResolvedFinding, mode: StrangerMode) -> some View {
        Button {
            withAnimation(.snappy) {
                if unfurled.contains(finding.id) {
                    unfurled.remove(finding.id)
                } else {
                    unfurled.insert(finding.id)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: unfurled.contains(finding.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(finding.topic)
                    .font(.system(size: 19, weight: .bold, design: .serif))
                Text("\(finding.entries.count) document\(finding.entries.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        Text(finding.position)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
        if unfurled.contains(finding.id) {
            Text(finding.answer)
                .font(.callout)
                .italic()
                .padding(.leading, 36)
                .padding(.top, 4)
            ForEach(finding.entries) { entry in
                Button {
                    model.openInLibrary(entry.doc)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.doc.title)
                        Text("\(entry.doc.displayAuthor) · \(entry.doc.listedDateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 54)
                .padding(.vertical, 2)
            }
        }
    }

    private func questionView(_ question: String, mode: StrangerMode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mode == .challenge
                 ? "The question the community writes around"
                 : "The question the community is close to answering")
                .font(.system(size: 19, weight: .bold, design: .serif))
            Text(question)
                .font(.callout)
                .italic()
                .padding(.leading, 18)
        }
        .padding(.top, 10)
    }

    /// The Stranger's request to switch modes — reciprocal signalling:
    /// the model may ask, only the reader grants.
    private func modeRequestView(_ reason: String, from current: StrangerMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The Stranger asks to switch to \(current.other.rawValue)")
                .font(.headline)
            Text(reason)
                .font(.callout)
                .italic()
            HStack {
                Button("Let It — Read Again as \(current.other.rawValue)") {
                    mode = current.other
                    run()
                }
                Button("Not Now") {
                    guard let reading else { return }
                    self.reading = StrangerReading(mode: reading.mode,
                                                   findings: reading.findings,
                                                   question: reading.question,
                                                   modeRequest: nil)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }

    // MARK: - Running the model

    private func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence."
        case .modelNotReady:
            return "The model is still preparing; try again shortly."
        default:
            return "Enable Apple Intelligence in System Settings to use it."
        }
    }

    private func run() {
        isRunning = true
        errorText = nil
        let corpus = AIInsights.corpus(from: Array(model.index.byID.values))
        guard corpus.includedCount > 0 else {
            errorText = "No text documents in the library yet."
            isRunning = false
            return
        }
        var fullPrompt = mode == .challenge ? challengePrompt : supportPrompt
        if mode == .challenge {
            let unchallenged = unchallengedByLinks().prefix(8)
            if !unchallenged.isEmpty {
                fullPrompt += "\n\nSUPPORTED BY LINKS, NEVER CHALLENGED: "
                    + unchallenged.map { "[\($0)]" }.joined(separator: " ")
            }
        }
        fullPrompt += "\n\nTHE DOCUMENTS (\(corpus.includedCount) included"
        if corpus.omittedCount > 0 {
            fullPrompt += ", \(corpus.omittedCount) older omitted for space"
        }
        fullPrompt += "):\n\n" + corpus.text
        let request = fullPrompt
        let requestMode = mode
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: request, generating: GeneratedStrangerReading.self)
                let generated = response.content
                reading = StrangerReading(
                    mode: requestMode,
                    findings: resolve(generated.findings),
                    question: generated.question.trimmingCharacters(in: .whitespaces),
                    modeRequest: generated.suggestsOtherMode && !generated.modeSwitchReason.isEmpty
                        ? generated.modeSwitchReason : nil)
                unfurled = []
            } catch {
                errorText = "The model could not respond: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    /// Grounding: unknown addresses are dropped, and a finding must keep
    /// at least one real document to survive.
    private func resolve(_ generated: [GeneratedStrangerFinding]) -> [ResolvedFinding] {
        let byID = model.index.byID
        return generated.compactMap { finding in
            var seen: Set<String> = []
            let entries = finding.addresses
                .map { LiquidAddress.canonical($0) }
                .filter { seen.insert($0).inserted }
                .compactMap { byID[$0] }
            guard !entries.isEmpty else { return nil }
            return ResolvedFinding(topic: finding.topic, position: finding.position,
                                   answer: finding.answer, entries: entries)
        }
    }

    /// The link-level consensus signal, computed before the model reads:
    /// documents that receive supports or extends links and not one
    /// disagrees-with or questions.
    private func unchallengedByLinks() -> [String] {
        var supported: Set<String> = []
        var challenged: Set<String> = []
        let byID = model.index.byID
        for entry in byID.values {
            for link in entry.doc.links {
                let target = model.index.latestRevision(of: LiquidAddress.canonical(link.to))
                guard byID[target] != nil, target != entry.id else { continue }
                switch link.rel {
                case "supports", "extends": supported.insert(target)
                case "disagrees-with", "questions": challenged.insert(target)
                default: break
                }
            }
        }
        return supported.subtracting(challenged).sorted()
    }

    // MARK: - On the record

    /// The reading becomes a document in the community folder: machine
    /// authorship declared (`aiOnBehalf`), each finding linked to the
    /// documents it answers — questions in challenge, supports in support
    /// — so the Stranger's statement takes its place in the document web
    /// like anything else on the record.
    private func putOnRecord(_ reading: StrangerReading) {
        guard let folder = model.index.folderURL else {
            model.showNote("Choose a community folder first — the record lives there.")
            return
        }
        let created = Date.now
        let author = "The Stranger"
        let taken = Set(model.index.byID.keys)
        let id = LiquidAddress.makeID(author: author, created: created,
                                      isTaken: { taken.contains($0) })
        var paragraphs: [LiquidDoc.Paragraph] = []
        var links: [LiquidDoc.Link] = []
        var linked: Set<String> = []
        var counter = 0
        func add(_ text: String, heading: Int? = nil) {
            counter += 1
            paragraphs.append(LiquidDoc.Paragraph(id: "p\(counter)", heading: heading, text: text))
        }
        add("This document is machine-written. The Stranger is an AI reader standing both inside and outside this community — after Georg Simmel's stranger, by way of David Millard — summoned in \(reading.mode.rawValue.lowercased()) mode by a reader of this library. Its statements carry no authority beyond their reasons, and they are on the record so the community can answer them.")
        for finding in reading.findings {
            add(finding.topic, heading: 2)
            let addresses = finding.entries.map { "[\($0.id)]" }.joined(separator: " ")
            add("\(finding.position) \(addresses)")
            add(finding.answer)
            for entry in finding.entries where linked.insert(entry.id).inserted {
                links.append(LiquidDoc.Link(to: entry.id, fragment: nil, rel: reading.mode.recordRel))
            }
        }
        if !reading.question.isEmpty {
            add("The Stranger's question", heading: 2)
            add(reading.question)
        }
        let title = reading.mode == .challenge ? "A Stranger's Challenge" : "A Stranger's Support"
        // The standard slug--id file name convention.
        let slug = LiquidDoc.fileSlug(from: title)
        let ext = LiquidDoc.fileExtension
        let fileName = slug.isEmpty ? "\(id).\(ext)" : "\(slug)--\(id).\(ext)"
        var doc = LiquidDoc(format: LiquidDoc.knownFormat,
                            id: id,
                            title: title,
                            author: author,
                            created: created,
                            body: paragraphs,
                            links: links,
                            wraps: nil,
                            fileURL: folder.appendingPathComponent(fileName))
        doc.aiOnBehalf = true
        let finished = VisualMeta.appendingAppendix(to: doc)
        do {
            try finished.jsonData().write(to: finished.fileURL, options: .atomic)
            model.showNote("“\(title)” is on the record.")
        } catch {
            model.showNote("Could not put the reading on the record: \(error.localizedDescription)")
        }
    }
}

extension StrangerView {
    /// The Stranger as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "the-stranger",
        name: "The Stranger",
        systemImage: "person.fill.questionmark",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(StrangerView()) },
        hidesDocumentList: true
    )
}
