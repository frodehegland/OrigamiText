import SwiftUI

// Ask the Library: a question answered from the library's own passages.
// The app finds the passages that best match the question — across every
// book and document — and hands them, numbered, to the model chosen in
// Settings ▸ AI (Apple's on-device model when none is chosen or it cannot
// answer). The answer must cite passages by number; each citation becomes
// a link to its exact paragraph, and a number the model invents (one no
// passage carries) is dropped, never shown as a source.

/// One passage offered to the model, with where it lives.
private struct LibraryPassage: Identifiable {
    let id: Int
    let docID: String
    let paragraphID: String
    let title: String
    let author: String
    let text: String

    var link: String? {
        AppModel.paragraphLink(bookAddress: docID, fragment: paragraphID)
    }
}

/// Ask the Library: grounded question-answering over the library, every
/// citation a link to the passage it rests on.
struct AskLibraryView: View {
    @Environment(AppModel.self) private var state

    @State private var question = ""
    @State private var answer = ""
    @State private var sources: [LibraryPassage] = []
    @State private var isAsking = false
    @State private var errorText: String?
    @State private var modelName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask the Library")
                .font(.system(size: 26, weight: .bold, design: .serif))
            Text("A question answered from the passages in your library. The best-matching passages go to the model chosen in Settings \u{25B8} AI, and every source it cites is a link to the paragraph it came from.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("What does my library say about\u{2026}", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { ask() }
                Button(isAsking ? "Asking\u{2026}" : "Ask") { ask() }
                    .disabled(isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !answer.isEmpty {
                        Text(renderedAnswer)
                            .font(.system(size: 15, design: .serif))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                    if !sources.isEmpty && !answer.isEmpty {
                        Divider()
                        Text("Sources").font(.headline)
                        ForEach(sources) { passage in
                            Button {
                                openPassage(passage)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(passage.id)] \(passage.title)").font(.callout.bold())
                                    Text(passage.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open this passage")
                        }
                        if let modelName {
                            Text("Answered by \(modelName), from your library's passages.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppGreys.page)
        // Citation links open their passage here, not in a browser.
        .environment(\.openURL, OpenURLAction { url in
            state.handleURL(url)
            return .handled
        })
    }

    /// The answer with each valid [n] a link to its passage; numbers no
    /// passage carries are removed.
    private var renderedAnswer: AttributedString {
        var text = answer
        if let expression = try? NSRegularExpression(pattern: #"\[(\d+(?:\s*,\s*\d+)*)\]"#) {
            let ns = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let numbers = ns.substring(with: match.range(at: 1))
                    .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let links = numbers.compactMap { n -> String? in
                    guard let passage = sources.first(where: { $0.id == n }), let link = passage.link else { return nil }
                    return "[\(n)](\(link))"
                }
                text = (text as NSString).replacingCharacters(
                    in: match.range, with: links.isEmpty ? "" : "[" + links.joined(separator: ", ") + "]")
            }
        }
        return (try? AttributedString(markdown: text,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private func openPassage(_ passage: LibraryPassage) {
        if state.epubRecord(forAddress: passage.docID) != nil {
            state.openEPUB(address: passage.docID, fragment: passage.paragraphID)
        } else {
            state.follow(to: passage.docID, fragment: passage.paragraphID, rel: nil)
        }
    }

    private func ask() {
        let asked = question.trimmingCharacters(in: .whitespaces)
        guard !asked.isEmpty, !isAsking else { return }
        let passages = Self.passages(for: asked, in: state.index)
        guard !passages.isEmpty else {
            answer = ""
            sources = []
            errorText = "Nothing in the library matches those words."
            return
        }
        isAsking = true
        errorText = nil
        answer = ""
        sources = passages
        let context = passages.map { "[\($0.id)] \u{201C}\($0.title)\u{201D} (\($0.author)): \($0.text)" }
            .joined(separator: "\n\n")
        let instructions = """
            You are the librarian of a personal research library. Answer only from the \
            numbered passages given. Keep the answer short and plain. After every claim, \
            cite the passage it came from by its number in square brackets, like [3]. \
            If the passages do not answer the question, say so plainly.
            """
        let prompt = "Passages:\n\n\(context)\n\nQuestion: \(asked)"
        Task {
            do {
                let result = try await OrigamiLLM.shared.respond(instructions: instructions, to: prompt) { partial in
                    answer = partial
                }
                answer = result.text
                modelName = result.modelName
            } catch {
                errorText = "The model could not answer: \(error.localizedDescription)"
            }
            isAsking = false
        }
    }

    /// The passages that best match the question: paragraphs scored by
    /// how many of its words they hold, at most three per document.
    @MainActor
    private static func passages(for question: String, in index: LibraryIndex) -> [LibraryPassage] {
        let stopwords: Set<String> = ["the", "and", "for", "with", "what", "does", "about", "that", "this",
                                      "from", "have", "how", "why", "who", "are", "was", "were", "which",
                                      "into", "their", "there", "they", "say", "says", "library", "my"]
        let terms = Set(question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) })
        guard !terms.isEmpty else { return [] }
        var scored: [(score: Int, doc: LiquidDoc, paragraph: LiquidDoc.Paragraph)] = []
        for entry in index.allByID.values {
            var perDoc: [(Int, LiquidDoc.Paragraph)] = []
            for paragraph in entry.doc.body ?? [] where paragraph.heading == nil && paragraph.text.count > 60 {
                let words = paragraph.text.lowercased()
                let score = terms.reduce(0) { $0 + (words.contains($1) ? 1 : 0) }
                if score > 0 { perDoc.append((score, paragraph)) }
            }
            for (score, paragraph) in perDoc.sorted(by: { $0.0 > $1.0 }).prefix(3) {
                scored.append((score, entry.doc, paragraph))
            }
        }
        return scored.sorted { $0.score > $1.score }.prefix(12).enumerated().map { offset, hit in
            LibraryPassage(id: offset + 1, docID: hit.doc.id, paragraphID: hit.paragraph.id,
                           title: hit.doc.title, author: hit.doc.displayAuthor,
                           text: String(CitedHereText.readable(hit.paragraph.text).prefix(700)))
        }
    }
}

/// A paragraph's words for the model: the reader's text, tokens dropped.
private enum CitedHereText {
    static func readable(_ text: String) -> String { AppModel.readableWords(text) }
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
