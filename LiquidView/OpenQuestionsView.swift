import SwiftUI
import FoundationModels

/// Defaults for the Open Questions view. Runs entirely on-device (Apple
/// Intelligence); no text leaves the Mac. The prompt is editable in
/// Settings → AI.
nonisolated enum OpenQuestions {

    static let defaultPrompt = """
    You are reading a community of thinkers' documents to surface the open questions: what is genuinely unresolved and still being worked out across these documents. Questions the community is asking — explicitly or between the lines — not questions you would ask about the documents.

    How to read the material: each document begins with a == line giving its title, author, date, and address. A following Relations: line is metadata — typed links between documents — treat it as structure, never as prose. Anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata about a document, not content; disregard it as text even if fragments appear.

    Name between three and eight open questions, most alive first. Each needs: the question itself, phrased in one sentence as the community would ask it; one sentence on where the thinking currently stands; and the addresses of the documents that raise it or bear on it, copied exactly from their == lines. Prefer questions several documents circle around. A question one document has already settled is not open. Never invent an address.
    """
}

/// One open question as the model returns it; addresses are verified
/// against the index before display.
@Generable
nonisolated struct GeneratedQuestion {
    @Guide(description: "The open question itself, one sentence, phrased as the community would ask it")
    var question: String
    @Guide(description: "One sentence on where the community's thinking on it currently stands")
    var status: String
    @Guide(description: "Addresses of the documents that raise this question or bear on it, copied exactly from the == lines, e.g. f.hegla.093000k")
    var addresses: [String]
}

@Generable
nonisolated struct GeneratedQuestionList {
    @Guide(description: "The open questions across the documents, most alive first")
    var questions: [GeneratedQuestion]
}

/// What the community has not settled yet: the on-device model reads the
/// library and names the live questions. Each unfurls to the documents
/// that raise it.
struct OpenQuestionsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.aiOpenQuestionsPromptKey) private var prompt = OpenQuestions.defaultPrompt
    @State private var questions: [ResolvedQuestion] = []
    @State private var hasRun = false
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var unfurled: Set<String> = []

    struct ResolvedQuestion: Identifiable {
        let question: String
        let status: String
        let entries: [IndexEntry]
        var id: String { question }
    }

    var body: some View {
        Group {
            switch SystemLanguageModel.default.availability {
            case .available:
                content
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Apple Intelligence Unavailable", systemImage: "questionmark.circle")
                } description: {
                    Text("Open Questions uses the on-device model, so no text leaves this Mac. \(describe(reason))")
                }
            }
        }
        .navigationTitle("Open Questions")
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        run()
                    } label: {
                        Label(isRunning ? "Reading…" : (hasRun ? "Find Questions Again" : "Find Open Questions"),
                              systemImage: "questionmark.circle")
                    }
                    .disabled(isRunning)
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if !hasRun, !isRunning {
                    Text("The on-device model reads every document in the library and names what the community is still working out — the questions no document has settled. Each opens to its documents. The prompt is yours: Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if hasRun, questions.isEmpty, !isRunning {
                    Text("No open questions grounded in library documents came back. Try again, or adjust the prompt in Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(questions) { question in
                    questionRow(question)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    @ViewBuilder
    private func questionRow(_ question: ResolvedQuestion) -> some View {
        Button {
            withAnimation(.snappy) {
                if unfurled.contains(question.id) {
                    unfurled.remove(question.id)
                } else {
                    unfurled.insert(question.id)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: unfurled.contains(question.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(question.question)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .multilineTextAlignment(.leading)
                Text("\(question.entries.count)")
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
        Text(question.status)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
        if unfurled.contains(question.id) {
            ForEach(question.entries) { entry in
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
                .padding(.leading, 36)
                .padding(.vertical, 2)
            }
        }
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
        var fullPrompt = prompt
        fullPrompt += "\n\nTHE DOCUMENTS (\(corpus.includedCount) included"
        if corpus.omittedCount > 0 {
            fullPrompt += ", \(corpus.omittedCount) older omitted for space"
        }
        fullPrompt += "):\n\n" + corpus.text
        let request = fullPrompt
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: request, generating: GeneratedQuestionList.self)
                questions = resolve(response.content.questions)
                unfurled = []
                hasRun = true
            } catch {
                errorText = "The model could not respond: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    /// Grounding: unknown addresses are dropped; a question with no real
    /// documents left disappears with them.
    private func resolve(_ generated: [GeneratedQuestion]) -> [ResolvedQuestion] {
        generated.compactMap { question in
            var seen: Set<String> = []
            let entries = question.addresses
                .map { LiquidAddress.canonical($0) }
                .filter { seen.insert($0).inserted }
                .compactMap { model.index.byID[$0] }
            guard !entries.isEmpty else { return nil }
            return ResolvedQuestion(question: question.question, status: question.status, entries: entries)
        }
    }
}

extension OpenQuestionsView {
    /// The Open Questions view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "open-questions",
        name: "Open Questions",
        systemImage: "questionmark.circle",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(OpenQuestionsView()) },
        hidesDocumentList: true
    )
}
