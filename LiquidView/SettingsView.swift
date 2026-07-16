import SwiftUI
import AppKit

/// UserDefaults keys for user-facing settings.
enum AppSettings {
    static let hideHeadingMarkersKey = "hideHeadingMarkers"
    static let hideVisualMetaKey = "hideVisualMeta"
    static let fullScreenContentWidthKey = "fullScreenContentWidth"
    static let authorNameKey = "authorName"
    static let authorTitleKey = "authorTitle"
    static let authorORCIDKey = "authorORCID"
    static let authorAffiliationKey = "authorAffiliation"
    static let testAccountActiveKey = "testAccountActive"
    static let testAccountNameKey = "testAccountName"
    static let aiInsightsPromptKey = "aiInsightsPrompt"
    static let aiThemesPromptKey = "aiThemesPrompt"
    static let aiOpenQuestionsPromptKey = "aiOpenQuestionsPrompt"
    static let aiDisagreementsPromptKey = "aiDisagreementsPrompt"
    static let aiAgreementsPromptKey = "aiAgreementsPrompt"
}

/// The app's Settings window (Origami Text → Settings…, ⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            AuthorSettingsView()
                .tabItem { Label("Author", systemImage: "person.text.rectangle") }
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "square.and.pencil") }
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            ModulesSettingsView()
                .tabItem { Label("View Modules", systemImage: "puzzlepiece.extension") }
            FormatSettingsView()
                .tabItem { Label("Format", systemImage: "doc.text") }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Who is writing: used as the default author of new documents and in the
/// Visual-Meta self-citation of exported documents.
private struct AuthorSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.authorNameKey) private var name = ""
    @AppStorage(AppSettings.authorTitleKey) private var title = ""
    @AppStorage(AppSettings.authorORCIDKey) private var orcid = ""
    @AppStorage(AppSettings.authorAffiliationKey) private var affiliation = ""
    @State private var muteName = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(NSFullUserName()))
                Picker("Title", selection: $title) {
                    Text("None").tag("")
                    ForEach(["Dr.", "Prof.", "Prof. Dr.", "Mr.", "Ms.", "Mrs.", "Mx."], id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                TextField("ORCID", text: $orcid, prompt: Text("0000-0002-1825-0097"))
                TextField("Affiliation", text: $affiliation, prompt: Text("University or organisation"))
            } footer: {
                Text("Used as the default author for new documents. Title, ORCID, and affiliation are included in the Visual-Meta self-citation when you export a document whose author matches your name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(model.isTestAccountActive)
            Section {
                Toggle("Act as test account", isOn: $model.isTestAccountActive)
                if model.isTestAccountActive {
                    TextField("Test name", text: $model.testAccountName)
                }
            } header: {
                Text("Test Account")
            } footer: {
                Text("While active, the app takes on this identity everywhere: new documents are authored by it, and the library bolds documents addressed to it. Name only — your title, ORCID, and affiliation are never attached. Switch off to return to yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                if model.mutedAuthors.isEmpty {
                    Text("No one is muted.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.mutedAuthors, id: \.self) { mutedName in
                    LabeledContent(mutedName) {
                        Button("Unmute") {
                            model.mutedAuthors.removeAll { $0 == mutedName }
                        }
                    }
                }
                HStack {
                    TextField("Name to mute", text: $muteName)
                    Button("Mute") {
                        let trimmed = muteName.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !model.isMuted(trimmed) else { return }
                        model.mutedAuthors.append(trimmed)
                        muteName = ""
                    }
                    .disabled(muteName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Muted People")
            } footer: {
                Text("Documents from muted people are not shown in the library lists. Their files stay in the library folder untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The prompts behind the AI views, fully user-owned. Every AI view runs
/// on this Mac only — no text leaves it. One editor, a picker to choose
/// which view's prompt it edits — the list grows as AI views do.
private struct AISettingsView: View {
    @AppStorage(AppSettings.aiInsightsPromptKey) private var insightsPrompt = AIInsights.defaultPrompt
    @AppStorage(AppSettings.aiThemesPromptKey) private var themesPrompt = Themes.defaultPrompt
    @AppStorage(AppSettings.aiOpenQuestionsPromptKey) private var questionsPrompt = OpenQuestions.defaultPrompt
    @AppStorage(AppSettings.aiDisagreementsPromptKey) private var disagreementsPrompt = Disagreements.defaultPrompt
    @AppStorage(AppSettings.aiAgreementsPromptKey) private var agreementsPrompt = Agreements.defaultPrompt
    @State private var selection = "AI Insights"

    private var prompt: Binding<String> {
        switch selection {
        case "Themes": $themesPrompt
        case "Open Questions": $questionsPrompt
        case "Agreements": $agreementsPrompt
        case "Disagreements": $disagreementsPrompt
        default: $insightsPrompt
        }
    }

    private var defaultValue: String {
        switch selection {
        case "Themes": Themes.defaultPrompt
        case "Open Questions": OpenQuestions.defaultPrompt
        case "Agreements": Agreements.defaultPrompt
        case "Disagreements": Disagreements.defaultPrompt
        default: AIInsights.defaultPrompt
        }
    }

    private var note: String {
        switch selection {
        case "Themes":
            "Names the themes shown in the Themes view. The response is constrained to a list of themes, each grounded in document addresses — addresses that don't exist in the library are dropped."
        case "Open Questions":
            "Names what the community has not settled. The response is constrained to a list of questions, each grounded in real document addresses."
        case "Agreements":
            "Names where documents genuinely converge. An agreement survives only when at least two real documents hold the shared position — one document cannot agree with itself."
        case "Disagreements":
            "Names where documents genuinely pull apart. Each dispute keeps only sides grounded in real documents — both sides must survive or the dispute is dropped."
        default:
            "The AI Insights report. Citing documents by bracketed address makes the model's references live links."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Prompt", selection: $selection) {
                    ForEach(["AI Insights", "Themes", "Open Questions", "Agreements", "Disagreements"], id: \.self) {
                        Text($0)
                    }
                }
                .pickerStyle(.menu)
                TextEditor(text: prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 260)
            } header: {
                Text("AI View Prompts")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Runs on this Mac only — no text leaves it. The library's documents are appended after the prompt, newest first, with typed links passed as marked metadata and Visual-Meta appendices excluded as content. \(note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset to Default") { prompt.wrappedValue = defaultValue }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Views are exchangeable modules — this tab explains how to write and
/// share one, and lists what's installed.
private struct ModulesSettingsView: View {

    var body: some View {
        Form {
            Section {
                Text("Every view in the sidebar's Views section is a module: one Swift file anyone can write, share, and install. Views are how a community grows its own ways of seeing — the documents stay the same; the ways of looking multiply.")
                    .font(.callout)
            }
            Section("Installed Views") {
                ForEach(LibraryViewRegistry.modules) { module in
                    LabeledContent {
                        Text(module.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(module.name, systemImage: module.systemImage)
                    }
                }
            }
            Section {
                Text("""
                1.  Write a SwiftUI view in one file. Read the library through the environment model — the document index, backlinks, and the ready-made derivations in LibraryInsights. Navigate with the same calls every view uses: openInLibrary, open(doc, fragment:), openTranspointing.
                2.  At the bottom of the file, declare a LibraryViewModule: an id, a sidebar name, an SF Symbol, and how to build its panes.
                3.  Add that module to LibraryViewRegistry.modules — one line. The sidebar entry, selection, and routing follow automatically.

                To share a view, send the file. To install one, drop it into the project and add its registry line. The full contract is documented in LibraryViewModule.swift.
                """)
                .font(.callout)
            } header: {
                Text("Create Your Own")
            } footer: {
                Button("Copy Starter Module") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(Self.starterTemplate, forType: .string)
                }
                .help("Puts a compilable starter view module on the clipboard")
            }
        }
        .formStyle(.grouped)
    }

    private static let starterTemplate = """
    import SwiftUI

    /// My View: <what it shows, and the cognitive job it does>.
    struct MyCommunityView: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            List {
                ForEach(model.index.timeline) { entry in
                    Button {
                        model.openInLibrary(entry.doc)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.doc.title)
                            Text(entry.doc.author)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("My View")
        }
    }

    extension MyCommunityView {
        /// Install by adding `MyCommunityView.module` to
        /// LibraryViewRegistry.modules.
        @MainActor static let module = LibraryViewModule(
            id: "my-view",
            name: "My View",
            systemImage: "sparkles",
            makeContent: { AnyView(MyCommunityView()) }
        )
    }
    """
}

/// The documents that define the project — the format specification and
/// the community announcement — bundled with the app and opened from here.
private struct FormatSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("The Origami Document Format") {
                    Button("Open") { open("ORIGAMI-DOCUMENT-FORMAT") }
                }
                LabeledContent("Origami Text — What We Have Built") {
                    Button("Open") { open("ORIGAMI-TEXT-OVERVIEW") }
                }
            } footer: {
                Text("The complete .origamitext specification — self-contained, ready to hand to a person or an AI to build a compatible app — and the overview of what Origami Text does and why. Both open in your default Markdown app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func open(_ resource: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Where cited material lives outside the community folder.
private struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Community Folder") {
                    Text(model.index.folderURL?.path ?? "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Community Folder…") { model.chooseFolder() }
            } footer: {
                Text("The shared folder of Origami Documents that is the library — typically an iCloud folder your community publishes into. The folder of documents is the library; choosing a different folder changes what the whole app shows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Reader Library") {
                    Text(model.readerLibraryURL?.path ?? "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose Reader Library…") { model.chooseReaderLibrary() }
            } footer: {
                Text("Citations to PDFs resolve against Reader's library, so a cited PDF does not need to be in the community folder. Clicking such a citation opens the PDF in Reader.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Create Sample Community") { model.createSampleCommunity() }
                        .disabled(model.index.folderURL == nil)
                    Button("Remove Sample Community") { model.removeSampleCommunity() }
                        .disabled(model.index.folderURL == nil)
                }
            } header: {
                Text("Testing")
            } footer: {
                Text("Writes a small fictional community into the community folder — five authors in dialogue: letters, a response addressed to you, a disagreement, a superseding revision, a transcript, an extract lifted on a speaker's behalf, an RFC for your attention, and an AI-produced summary. Every file name begins with “sample--”; Remove deletes exactly those files and nothing else.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettingsView: View {
    @AppStorage(AppSettings.hideHeadingMarkersKey) private var hideHeadingMarkers = true
    @AppStorage(AppSettings.fullScreenContentWidthKey) private var fullScreenContentWidth = 760.0

    var body: some View {
        Form {
            Section {
                Toggle("Hide # heading markers while editing", isOn: $hideHeadingMarkers)
            } footer: {
                Text("Heading lines keep their #, ##, or ### in the saved document; this only hides the markers in the editor. When shown, markers appear dimmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Slider(value: $fullScreenContentWidth, in: 480...1200, step: 20) {
                    Text("Full screen text width")
                }
                LabeledContent("Width", value: "\(Int(fullScreenContentWidth)) points")
            } footer: {
                Text("How wide the text runs in full screen. Narrower text means wider margins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
