import SwiftUI
import FoundationModels

/// Defaults for the Agreements view. Runs entirely on-device (Apple
/// Intelligence); no text leaves the Mac. The prompt is editable in
/// Settings → AI.
nonisolated enum Agreements {

    static let defaultPrompt = """
    You are reading a community of thinkers' documents to surface genuine agreements: places where two or more documents independently take the same position on the same matter. Real convergence only — merely sharing a subject, or one document citing another without adopting its position, is not agreement.

    How to read the material: each document begins with a == line giving its title, author, date, and address. A following Relations: line is metadata — typed links between documents (a supports link is a strong signal, but the text itself can agree without one) — treat it as structure, never as prose. Anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata about a document, not content; disregard it as text even if fragments appear.

    Name up to six agreements, strongest first. Each needs: a topic of one to four words; one sentence stating exactly what is agreed; and the addresses of the documents sharing the position — at least two, copied exactly from their == lines. If the library holds no genuine agreement, return none — an empty list is an honest answer. Never invent an address.
    """
}

/// One agreement as the model returns it: the shared position and the
/// documents holding it. Addresses are verified against the index before
/// display.
@Generable
nonisolated struct GeneratedAgreement {
    @Guide(description: "The agreed topic: one to four words")
    var topic: String
    @Guide(description: "One sentence stating exactly what is agreed")
    var consensus: String
    @Guide(description: "Addresses of the documents sharing the position, copied exactly from the == lines, e.g. f.hegla.093000k — at least two")
    var addresses: [String]
}

@Generable
nonisolated struct GeneratedAgreementList {
    @Guide(description: "The genuine agreements across the documents, strongest first; empty if there are none")
    var agreements: [GeneratedAgreement]
}

/// Where the community genuinely converges: the on-device model reads the
/// library and names the shared positions, each with the documents that
/// independently hold it. Consensus deserves to be as visible as dispute.
struct AgreementsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.aiAgreementsPromptKey) private var prompt = Agreements.defaultPrompt
    @State private var agreements: [ResolvedAgreement] = []
    @State private var hasRun = false
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var unfurled: Set<String> = []

    /// An agreement that kept at least two real documents after grounding.
    struct ResolvedAgreement: Identifiable {
        let topic: String
        let consensus: String
        let entries: [IndexEntry]
        var id: String { topic }
    }

    var body: some View {
        Group {
            switch SystemLanguageModel.default.availability {
            case .available:
                content
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Apple Intelligence Unavailable", systemImage: "checkmark.bubble")
                } description: {
                    Text("Agreements uses the on-device model, so no text leaves this Mac. \(describe(reason))")
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
                        Label(isRunning ? "Reading…" : (hasRun ? "Find Agreements Again" : "Find Agreements"),
                              systemImage: "checkmark.bubble")
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
                    Text("The on-device model reads every document in the library and names where documents genuinely converge — each shared position with the documents that independently hold it. The prompt is yours: Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if hasRun, agreements.isEmpty, !isRunning {
                    Text("No genuine agreement found between library documents — an empty list is an honest answer. Try again as the library grows.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(agreements) { agreement in
                    agreementRow(agreement)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    @ViewBuilder
    private func agreementRow(_ agreement: ResolvedAgreement) -> some View {
        Button {
            withAnimation(.snappy) {
                if unfurled.contains(agreement.id) {
                    unfurled.remove(agreement.id)
                } else {
                    unfurled.insert(agreement.id)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: unfurled.contains(agreement.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(agreement.topic)
                    .font(.system(size: 19, weight: .bold, design: .serif))
                Text("\(agreement.entries.count) documents")
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
        Text(agreement.consensus)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
        if unfurled.contains(agreement.id) {
            ForEach(agreement.entries) { entry in
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
                let response = try await session.respond(to: request, generating: GeneratedAgreementList.self)
                agreements = resolve(response.content.agreements)
                unfurled = []
                hasRun = true
            } catch {
                errorText = "The model could not respond: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    /// Grounding: unknown addresses are dropped, duplicates collapse, and
    /// an agreement must keep at least two real documents to survive — one
    /// document cannot agree with itself.
    private func resolve(_ generated: [GeneratedAgreement]) -> [ResolvedAgreement] {
        let byID = model.index.byID
        return generated.compactMap { agreement in
            var seen: Set<String> = []
            let entries = agreement.addresses
                .map { LiquidAddress.canonical($0) }
                .filter { seen.insert($0).inserted }
                .compactMap { byID[$0] }
            guard entries.count >= 2 else { return nil }
            return ResolvedAgreement(topic: agreement.topic,
                                     consensus: agreement.consensus,
                                     entries: entries)
        }
    }
}

extension AgreementsView {
    /// The Agreements view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "agreements",
        name: "Agreements",
        systemImage: "checkmark.bubble",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(AgreementsView()) },
        hidesDocumentList: true
    )
}
