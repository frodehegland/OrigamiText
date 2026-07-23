import SwiftUI
import FoundationModels

/// Defaults for the Disagreements view. Runs entirely on-device (Apple
/// Intelligence); no text leaves the Mac. The prompt is editable in
/// Settings → AI.
nonisolated enum Disagreements {

    static let defaultPrompt = """
    You are reading a community of thinkers' documents to surface genuine disagreements: places where documents take positions that cannot both be right, or authors pull in different directions on the same matter. Real tension only — a difference of emphasis or subject is not disagreement.

    How to read the material: each document begins with a == line giving its title, author, date, and address. A following Relations: line is metadata — typed links between documents (a disagrees-with link is a strong signal, but the text itself can disagree without one) — treat it as structure, never as prose. Anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata about a document, not content; disregard it as text even if fragments appear.

    Name up to six disagreements, sharpest first. Each needs: a topic of one to four words; one sentence stating exactly what is in dispute; and the two positions, each in one sentence with the addresses of the documents taking it, copied exactly from their == lines. A document belongs on only one side of a given disagreement. If the library holds no genuine disagreement, return none — an empty list is an honest answer. Never invent an address.
    """
}

/// One disagreement as the model returns it: the dispute and its two
/// sides. Addresses are verified against the index before display.
@Generable
nonisolated struct GeneratedDisagreement {
    @Guide(description: "The disputed topic: one to four words")
    var topic: String
    @Guide(description: "One sentence stating exactly what is in dispute")
    var dispute: String
    @Guide(description: "The first position, in one sentence")
    var firstPosition: String
    @Guide(description: "Addresses of the documents taking the first position, copied exactly from the == lines, e.g. f.hegla.093000k")
    var firstAddresses: [String]
    @Guide(description: "The second position, in one sentence")
    var secondPosition: String
    @Guide(description: "Addresses of the documents taking the second position, copied exactly from the == lines")
    var secondAddresses: [String]
}

@Generable
nonisolated struct GeneratedDisagreementList {
    @Guide(description: "The genuine disagreements across the documents, sharpest first; empty if there are none")
    var disagreements: [GeneratedDisagreement]
}

/// Where the community genuinely pulls apart: the on-device model reads
/// the library and names the disputes, each with its two sides and the
/// documents holding them. Dialog needs its disagreements visible.
struct DisagreementsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.aiDisagreementsPromptKey) private var prompt = Disagreements.defaultPrompt
    @State private var disagreements: [ResolvedDisagreement] = []
    @State private var hasRun = false
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var unfurled: Set<String> = []

    /// A disagreement both of whose sides survived grounding.
    struct ResolvedDisagreement: Identifiable {
        struct Side {
            let position: String
            let entries: [IndexEntry]
        }
        let topic: String
        let dispute: String
        let first: Side
        let second: Side
        var id: String { topic }
    }

    var body: some View {
        Group {
            switch SystemLanguageModel.default.availability {
            case .available:
                content
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Apple Intelligence Unavailable", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Disagreements uses the on-device model, so no text leaves this Mac. \(describe(reason))")
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
                        Label(isRunning ? "Reading…" : (hasRun ? "Find Disagreements Again" : "Find Disagreements"),
                              systemImage: "bubble.left.and.bubble.right")
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
                    Text("The on-device model reads every document in the library and names where documents genuinely pull against each other — each dispute with its two sides and their documents. The prompt is yours: Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if hasRun, disagreements.isEmpty, !isRunning {
                    Text("No genuine disagreement found between library documents — an empty list is an honest answer. Try again as the library grows.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(disagreements) { disagreement in
                    disagreementRow(disagreement)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    @ViewBuilder
    private func disagreementRow(_ disagreement: ResolvedDisagreement) -> some View {
        Button {
            withAnimation(.snappy) {
                if unfurled.contains(disagreement.id) {
                    unfurled.remove(disagreement.id)
                } else {
                    unfurled.insert(disagreement.id)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: unfurled.contains(disagreement.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(disagreement.topic)
                    .font(.system(size: 19, weight: .bold, design: .serif))
                Text("\(disagreement.first.entries.count) v \(disagreement.second.entries.count)")
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
        Text(disagreement.dispute)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
        if unfurled.contains(disagreement.id) {
            sideView(disagreement.first)
            sideView(disagreement.second)
        }
    }

    @ViewBuilder
    private func sideView(_ side: ResolvedDisagreement.Side) -> some View {
        Text(side.position)
            .font(.callout)
            .italic()
            .padding(.leading, 36)
            .padding(.top, 4)
        ForEach(side.entries) { entry in
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
                let response = try await session.respond(to: request, generating: GeneratedDisagreementList.self)
                disagreements = resolve(response.content.disagreements)
                unfurled = []
                hasRun = true
            } catch {
                errorText = "The model could not respond: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    /// Grounding: unknown addresses are dropped, a document may hold only
    /// one side, and a disagreement must keep at least one real document
    /// on each side to survive.
    private func resolve(_ generated: [GeneratedDisagreement]) -> [ResolvedDisagreement] {
        let byID = model.index.byID
        return generated.compactMap { disagreement in
            var seen: Set<String> = []
            func entries(for addresses: [String]) -> [IndexEntry] {
                addresses
                    .map { LiquidAddress.canonical($0) }
                    .filter { seen.insert($0).inserted }
                    .compactMap { byID[$0] }
            }
            let first = entries(for: disagreement.firstAddresses)
            let second = entries(for: disagreement.secondAddresses)
            guard !first.isEmpty, !second.isEmpty else { return nil }
            return ResolvedDisagreement(
                topic: disagreement.topic,
                dispute: disagreement.dispute,
                first: .init(position: disagreement.firstPosition, entries: first),
                second: .init(position: disagreement.secondPosition, entries: second)
            )
        }
    }
}

extension DisagreementsView {
    /// The Disagreements view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "disagreements",
        name: "Disagreements",
        systemImage: "bubble.left.and.bubble.right",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(DisagreementsView()) },
        hidesDocumentList: true
    )
}
