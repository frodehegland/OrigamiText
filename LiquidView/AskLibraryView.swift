import SwiftUI
import FoundationModels

// Ask the Library: a question answered on this Mac, grounded in the
// community's documents. The on-device model is given two tools over
// the library index — search, and read a document — and instructions
// that answers must cite addresses. Addresses in the answer are then
// verified against the index: one that resolves becomes a live link,
// one that does not is stripped of its brackets — the model may
// misremember; the web of documents may not. Nothing leaves the Mac.

// MARK: - The library tools

/// Searches the library's words and titles; the model's way in.
private struct SearchLibraryTool: Tool {
    let name = "searchLibrary"
    let description = "Searches every document in the community library by words in the title, author, or body. Returns each match's address in [brackets], its title, author, and a snippet."

    let state: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "Words to search for")
        var query: String
        @Guide(description: "How many matches to return", .range(1...8))
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> [String] {
        let query = arguments.query
        let limit = arguments.limit
        return await MainActor.run {
            let terms = query.lowercased()
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard !terms.isEmpty else { return ["Nothing to search for."] }
            var results: [String] = []
            for entry in state.index.byID.values {
                let doc = entry.doc
                let haystack = (doc.title + " " + doc.author + " "
                    + doc.bodyEditingText).lowercased()
                guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
                let snippetSource = doc.bodyEditingText
                let snippet = String(snippetSource.prefix(160))
                    .replacingOccurrences(of: "\n", with: " ")
                results.append("[\(doc.id)] “\(doc.title)” by \(doc.displayAuthor), \(doc.listedDateText): \(snippet)")
                if results.count >= limit { break }
            }
            return results.isEmpty
                ? ["No documents match “\(query)”."]
                : results
        }
    }
}

/// Reads one document whole, by its address.
private struct ReadDocumentTool: Tool {
    let name = "readDocument"
    let description = "Reads a document by the address searchLibrary returned (without brackets). Returns its full words."

    let state: AppModel

    @Generable
    struct Arguments {
        @Guide(description: "The document's address, e.g. f.hegla.093252x")
        var address: String
    }

    func call(arguments: Arguments) async throws -> String {
        let address = arguments.address
        return await MainActor.run {
            let id = LiquidAddress.canonical(address)
            guard let doc = state.index.byID[id]?.doc
                ?? state.index.allByID[id]?.doc else {
                return "No document answers to \(address)."
            }
            // OT: Knowledge Space also unions doc.analysisParagraphIDs —
            // its notes' AI-analysis blocks, which Origami Text documents
            // never carry.
            let appendix = doc.visualMetaParagraphIDs
            let words = (doc.body ?? [])
                .filter { !appendix.contains($0.id) }
                .map(\.displayText)
                .joined(separator: "\n")
            return """
            “\(doc.title)” by \(doc.displayAuthor), \(doc.listedDateText) [\(doc.id)]:
            \(String(words.prefix(2500)))
            """
        }
    }
}

// MARK: - The view

/// Ask the Library: grounded question-answering over the community's
/// documents, on this Mac's own model, every citation verified.
struct AskLibraryView: View {
    @Environment(AppModel.self) private var state

    @State private var question = ""
    @State private var answer: [LiquidDoc.Paragraph] = []
    @State private var isAsking = false
    @State private var errorText: String?

    private var modelAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask the Library")
                .font(.system(size: 26, weight: .bold, design: .serif))
            Text("A question answered from the community's documents, on this Mac — the model must search the library, and every address it cites is verified against the index before it stands. Nothing leaves the machine.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("What does the community say about…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask() }
                Button(isAsking ? "Asking…" : "Ask") { ask() }
                    .disabled(isAsking || !modelAvailable
                              || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !modelAvailable {
                Text("The on-device model is not available on this Mac — Apple Intelligence is required.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(answer) { paragraph in
                        Text(paragraph.renderedText)
                            .font(.system(size: 15, design: .serif))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                    if !answer.isEmpty {
                        Divider()
                        Text("Answered by the on-device model, grounded by library search; addresses verified against the index.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppGreys.page)
    }

    private func ask() {
        let asked = question.trimmingCharacters(in: .whitespaces)
        guard !asked.isEmpty, !isAsking, modelAvailable else { return }
        isAsking = true
        errorText = nil
        answer = []
        let session = LanguageModelSession(
            tools: [SearchLibraryTool(state: state), ReadDocumentTool(state: state)],
            instructions: """
            You are the librarian of a small community's shared library of \
            documents. Answer questions only from what the library holds: \
            always search first, read documents when the snippets are not \
            enough, and keep answers short and grounded. Every claim must \
            cite the document it came from by putting its address in square \
            brackets, like [f.hegla.093252x], at the end of the sentence it \
            supports. If the library holds nothing on the question, say so \
            plainly.
            """)
        Task {
            do {
                let response = try await session.respond(to: asked)
                answer = Self.verifiedParagraphs(from: response.content,
                                                 index: state.index)
            } catch {
                errorText = "The model could not answer: \(error.localizedDescription)"
            }
            isAsking = false
        }
    }

    /// The answer as paragraphs, its citations verified: an address the
    /// index knows becomes a live link (via renderedText); one it does
    /// not loses its brackets and stands as plain words.
    @MainActor
    private static func verifiedParagraphs(from text: String,
                                           index: LibraryIndex) -> [LiquidDoc.Paragraph] {
        var verified = text
        // Walk matches back to front so ranges stay valid while editing.
        let nsText = verified as NSString
        for match in LiquidAddress.matches(in: verified).reversed() {
            guard index.allByID[match.id] == nil else { continue }
            let cited = nsText.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            verified = (verified as NSString).replacingCharacters(
                in: match.range, with: cited)
        }
        return LiquidDoc.parseBody(from: verified)
    }
}

extension AskLibraryView {
    /// Ask the Library as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "ask-library",
        name: "Ask",
        systemImage: "questionmark.bubble",
        makeContent: { AnyView(AskLibraryView()) },
        makeDetail: { _ in AnyView(AskLibraryView()) },
        hidesDocumentList: true,
        showInAppetite: .text
    )
}
