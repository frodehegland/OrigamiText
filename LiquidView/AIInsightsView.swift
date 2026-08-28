import SwiftUI
import FoundationModels

/// Defaults and corpus assembly for the AI Insights view. Runs entirely
/// on-device (Apple Intelligence); no text leaves the Mac.
nonisolated enum AIInsights {

    /// The default prompt — editable in Settings → AI. It teaches the model
    /// to read Relations lines and any Visual-Meta/BibTeX remnants as
    /// metadata, never as content; to head each section with ## so the
    /// report unfurls section by section; and to cite documents by address
    /// so its references become live links.
    static let defaultPrompt = """
    You are reading a community of thinkers' documents so they can see their own work more clearly. Your job is augmentation — raising the group's collective capability — not summary for its own sake.

    How to read the material: each document begins with a == line giving its title, author, date, and address. A following Relations: line is metadata — typed links between documents (cites, responds-to, extends, supports, questions, disagrees-with, revises) — treat it as structure, never as prose. Anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata about a document, not content; disregard it as text even if fragments appear.

    Report in plain, concise prose in five sections, beginning each with a heading line of ## and the section name, exactly these:

    ## The live questions
    What this community is actually working out right now.

    ## Agreement and dispute
    Where documents support or contradict one another; name the documents.

    ## The unargued
    Assumptions several documents share but none examines.

    ## Missing connections
    Documents that bear on each other without linking; say why the pairing matters.

    ## The next document
    The one piece this community most needs someone to write.

    When you mention a document, include its address in brackets — e.g. [f.hegla.093252x] — so your reference becomes a live link. Do not flatter. Brevity honors the reader.
    """

    /// Assembles the library's text for the model: newest documents first
    /// within a character budget the on-device model can hold, Visual-Meta
    /// appendices excluded, relations passed as marked metadata.
    static func corpus(from entries: [IndexEntry],
                       characterBudget: Int = 14_000) -> (text: String, includedCount: Int, omittedCount: Int) {
        var blocks: [String] = []
        var total = 0
        var included = 0
        let ordered = entries.sorted { $0.doc.listedDate > $1.doc.listedDate }
        for entry in ordered {
            guard let body = entry.doc.body else { continue }
            let appendixIDs = entry.doc.visualMetaParagraphIDs
            let text = body
                .filter { !appendixIDs.contains($0.id) }
                .map(\.displayText)
                .joined(separator: "\n")
            var header = "== \"\(entry.doc.title)\" by \(entry.doc.displayAuthor) (\(entry.doc.listedDateText), address \(entry.id))"
            if !entry.doc.links.isEmpty {
                let relations = entry.doc.links.map { link in
                    "\(link.rel ?? "links-to") [\(link.to)\(link.fragment.map { "#\($0)" } ?? "")]"
                }.joined(separator: " · ")
                header += "\nRelations: \(relations)"
            }
            let block = header + "\n" + text
            guard total + block.count <= characterBudget else { break }
            blocks.append(block)
            total += block.count
            included += 1
        }
        let textDocumentCount = entries.filter { $0.doc.body != nil }.count
        return (blocks.joined(separator: "\n\n"),
                included,
                max(0, textDocumentCount - included))
    }
}

/// A view of what the community is thinking, written by the on-device
/// model reading every document's text (never its metadata). The report
/// arrives furled: headings show, and the reader unfurls what they want.
struct AIInsightsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.aiInsightsPromptKey) private var prompt = AIInsights.defaultPrompt
    @State private var output = ""
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var unfurledSections: Set<Int> = []

    var body: some View {
        Group {
            switch SystemLanguageModel.default.availability {
            case .available:
                content
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Apple Intelligence Unavailable", systemImage: "sparkles")
                } description: {
                    Text("AI Insights uses the on-device model, so no text leaves this Mac. \(describe(reason))")
                }
            }
        }
        // The model cites documents by address; clicking one leaves this
        // view for the reader, exactly as a human-written link would.
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme?.lowercased() == "origamitext" {
                let before = model.current?.doc.id
                model.handleURL(url)
                if model.current?.doc.id != before {
                    model.sidebarSelection = .allDocuments
                }
                return .handled
            }
            return .systemAction
        })
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        run()
                    } label: {
                        Label(isRunning ? "Reading…" : "Generate Insights", systemImage: "sparkles")
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
                if output.isEmpty, !isRunning {
                    Text("Reads the text of every document in the library — Visual-Meta appendices and link metadata are treated as metadata, not content — and reports what the community is working out. The prompt is yours: Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    report
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    // MARK: - The furled report

    private struct InsightSection: Identifiable {
        let id: Int
        let heading: LiquidDoc.Paragraph?
        let paragraphs: [LiquidDoc.Paragraph]
    }

    /// Groups the model's output at its headings. Text before the first
    /// heading is a preamble, always shown.
    private var sections: [InsightSection] {
        let body = LiquidDoc.parseBody(from: output)
        var result: [InsightSection] = []
        var heading: LiquidDoc.Paragraph?
        var current: [LiquidDoc.Paragraph] = []
        func flush() {
            if heading != nil || !current.isEmpty {
                result.append(InsightSection(id: result.count, heading: heading, paragraphs: current))
            }
            current = []
        }
        for paragraph in body {
            if paragraph.effectiveHeading != nil {
                flush()
                heading = paragraph
            } else {
                current.append(paragraph)
            }
        }
        flush()
        return result
    }

    @ViewBuilder private var report: some View {
        // Rendered through the same paragraph pipeline as any document, so
        // the addresses the model cites are live links.
        ForEach(sections) { section in
            if let heading = section.heading {
                Button {
                    withAnimation(.snappy) {
                        if unfurledSections.contains(section.id) {
                            unfurledSections.remove(section.id)
                        } else {
                            unfurledSections.insert(section.id)
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: unfurledSections.contains(section.id)
                              ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(heading.displayText)
                            .font(.system(size: 19, weight: .bold, design: .serif))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                if let first = section.paragraphs.first {
                    ParagraphView(paragraph: first, isHighlighted: false)
                        .padding(.leading, 18)
                }
                if unfurledSections.contains(section.id) {
                    ForEach(section.paragraphs.dropFirst()) { paragraph in
                        ParagraphView(paragraph: paragraph, isHighlighted: false)
                    }
                    .padding(.leading, 18)
                }
            } else {
                ForEach(section.paragraphs) { paragraph in
                    ParagraphView(paragraph: paragraph, isHighlighted: false)
                }
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
        output = ""
        unfurledSections = []
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
                let response = try await session.respond(to: request)
                output = response.content
            } catch {
                errorText = "The model could not respond: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }
}

extension AIInsightsView {
    /// The AI Insights view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "ai-insights",
        name: "AI Insights",
        systemImage: "sparkles",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(AIInsightsView()) },
        hidesDocumentList: true
    )
}
