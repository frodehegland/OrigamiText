import SwiftUI
import FoundationModels

/// Defaults for the Themes view. Runs entirely on-device (Apple
/// Intelligence); no text leaves the Mac. The prompt is editable in
/// Settings → AI.
nonisolated enum Themes {

    /// The default prompt. It teaches the model what a theme is (a thread
    /// of the conversation, not a keyword), how to read the corpus headers
    /// and metadata, and to ground every theme in real document addresses.
    static let defaultPrompt = """
    You are reading a community of thinkers' documents to surface the themes running through them: the recurring subjects, questions, and ideas that no single document owns but several share. Themes, not keywords — name the threads of the conversation the way a good editor would.

    How to read the material: each document begins with a == line giving its title, author, date, and address. A following Relations: line is metadata — typed links between documents — treat it as structure, never as prose. Anything resembling Visual-Meta or BibTeX (@{...} markers, key = {value} fields) is metadata about a document, not content; disregard it as text even if fragments appear.

    Name between four and ten themes, strongest first. Each theme needs: a name of one to four words; one sentence on what these documents are saying about it; and the addresses of the documents where it appears, copied exactly from their == lines. A theme that connects three documents is worth more than three themes with one document each. Most documents should find a home in some theme, but do not force weak fits, and never invent an address.
    """
}

/// One theme as the model returns it. Guided generation constrains the
/// shape; the addresses are verified against the index before display.
@Generable
nonisolated struct GeneratedTheme {
    @Guide(description: "The theme's name: one to four words")
    var name: String
    @Guide(description: "One sentence on what these documents say about this theme")
    var summary: String
    @Guide(description: "Addresses of the documents where this theme appears, copied exactly from the == lines, e.g. f.hegla.093000k")
    var addresses: [String]
}

@Generable
nonisolated struct GeneratedThemeList {
    @Guide(description: "The themes running through the documents, strongest first")
    var themes: [GeneratedTheme]
}

/// The living successor to a static key-terms list: the on-device model
/// reads the library and names the threads of the conversation. Each theme
/// unfurls to the documents that carry it.
struct ThemesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.aiThemesPromptKey) private var prompt = Themes.defaultPrompt
    @State private var themes: [ResolvedTheme] = []
    @State private var hasRun = false
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var unfurled: Set<String> = []

    /// A theme whose addresses all resolved to real library documents.
    struct ResolvedTheme: Identifiable {
        let name: String
        let summary: String
        let entries: [IndexEntry]
        var id: String { name }
    }

    var body: some View {
        Group {
            switch SystemLanguageModel.default.availability {
            case .available:
                content
            case .unavailable(let reason):
                ContentUnavailableView {
                    Label("Apple Intelligence Unavailable", systemImage: "tag")
                } description: {
                    Text("Themes uses the on-device model, so no text leaves this Mac. \(describe(reason))")
                }
            }
        }
        .navigationTitle("Themes")
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        run()
                    } label: {
                        Label(isRunning ? "Reading…" : (hasRun ? "Find Themes Again" : "Find Themes"),
                              systemImage: "tag")
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
                    Text("The on-device model reads every document in the library and names the themes running through them — a living list, not a static index. Each theme opens to its documents. The prompt is yours: Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if hasRun, themes.isEmpty, !isRunning {
                    Text("No themes grounded in library documents came back. Try again, or adjust the prompt in Settings → AI.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(themes) { theme in
                    themeRow(theme)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    @ViewBuilder
    private func themeRow(_ theme: ResolvedTheme) -> some View {
        Button {
            withAnimation(.snappy) {
                if unfurled.contains(theme.id) {
                    unfurled.remove(theme.id)
                } else {
                    unfurled.insert(theme.id)
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: unfurled.contains(theme.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(theme.name)
                    .font(.system(size: 19, weight: .bold, design: .serif))
                Text("\(theme.entries.count)")
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
        Text(theme.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.leading, 18)
        if unfurled.contains(theme.id) {
            ForEach(theme.entries) { entry in
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
                let response = try await session.respond(to: request, generating: GeneratedThemeList.self)
                themes = resolve(response.content.themes)
                unfurled = []
                hasRun = true
            } catch {
                errorText = "The model could not respond: \(error.localizedDescription)"
            }
            isRunning = false
        }
    }

    /// Grounding: every address must resolve to a real library document —
    /// unknown addresses are dropped, and a theme with no real documents
    /// left disappears with them.
    private func resolve(_ generated: [GeneratedTheme]) -> [ResolvedTheme] {
        generated.compactMap { theme in
            var seen: Set<String> = []
            let entries = theme.addresses
                .map { LiquidAddress.canonical($0) }
                .filter { seen.insert($0).inserted }
                .compactMap { model.index.byID[$0] }
            guard !entries.isEmpty else { return nil }
            return ResolvedTheme(name: theme.name, summary: theme.summary, entries: entries)
        }
    }
}

extension ThemesView {
    /// The Themes view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "themes",
        name: "Themes",
        systemImage: "tag",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(ThemesView()) },
        hidesDocumentList: true
    )
}
