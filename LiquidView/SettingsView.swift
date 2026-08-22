import SwiftUI
import AppKit
import ImagePlayground
import UniformTypeIdentifiers

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
    static let shareGeneralLocationKey = "shareGeneralLocation"
    static let testAccountNameKey = "testAccountName"
    static let aiInsightsPromptKey = "aiInsightsPrompt"
    static let aiThemesPromptKey = "aiThemesPrompt"
    static let aiOpenQuestionsPromptKey = "aiOpenQuestionsPrompt"
    static let aiDisagreementsPromptKey = "aiDisagreementsPrompt"
    static let aiAgreementsPromptKey = "aiAgreementsPrompt"
    static let aiPersonProfilePromptKey = "aiPersonProfilePrompt"
    static let aiStrangerChallengePromptKey = "aiStrangerChallengePrompt"
    static let aiStrangerSupportPromptKey = "aiStrangerSupportPrompt"
    static let aiPersonProfilesEnabledKey = "aiPersonProfilesEnabled"
    static let portraitStyleKey = "portraitStyle"
    static let portraitPromptKey = "portraitPrompt"
    static let portraitInstantProcessingKey = "portraitInstantProcessing"
    static let verifyCrossrefKey = "verifyReferencesCrossref"
    static let readerThemeKey = "readerTheme"
    static let readerBodyFontKey = "readerBodyFont"
    static let readerHeadingFontKey = "readerHeadingFont"
    static let readerLayoutStyleKey = "readerLayoutStyle"
    static let readerHeaderColumnWidthKey = "readerHeaderColumnWidth"
    static let connectionPortraitsKey = "connectionPortraits"
}

/// Where the reader puts a letter's title, byline, and controls.
enum ReaderLayoutStyle: String, CaseIterable, Identifiable {
    /// Above the text — the classic arrangement.
    case topOfLetters = "Top of Letters"
    /// Beside the text, leaving the reading view to the words alone.
    case rightColumn = "Right Column"
    var id: String { rawValue }
}

/// The Settings window's tabs, addressable so other parts of the app can
/// open Settings onto a particular one.
enum SettingsTab: Hashable {
    case author, editor, reading, layout, library, dialog, ai, modules, openSource
}

/// The app's Settings window (Origami Text → Settings…, ⌘,).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            AuthorSettingsView()
                .tabItem { Label("Author", systemImage: "person.text.rectangle") }
                .tag(SettingsTab.author)
            EditorSettingsView()
                .tabItem { Label("Editor", systemImage: "square.and.pencil") }
                .tag(SettingsTab.editor)
            ReadingSettingsView()
                .tabItem { Label("Reading", systemImage: "book") }
                .tag(SettingsTab.reading)
            LayoutSettingsView()
                .tabItem { Label("Layout", systemImage: "sidebar.right") }
                .tag(SettingsTab.layout)
            LibrarySettingsView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(SettingsTab.library)
            SharingSettingsView()
                .tabItem { Label("Dialog", systemImage: "bubble.left.and.bubble.right") }
                .tag(SettingsTab.dialog)
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            ModulesSettingsView()
                .tabItem { Label("View Modules", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.modules)
            OpenSourceSettingsView()
                .tabItem { Label("Open Source", systemImage: "shippingbox") }
                .tag(SettingsTab.openSource)
        }
        .frame(width: 576)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// How the reader arranges a letter around its text. The letter's
/// identity and controls live in the column on the right, as in
/// Knowledge Space; full screen alone puts the header with the words.
private struct LayoutSettingsView: View {
    @AppStorage(AppSettings.connectionPortraitsKey)
    private var connectionPortraits = true

    var body: some View {
        Form {
            Section {
                Toggle("Author portraits on connection cards", isOn: $connectionPortraits)
            } footer: {
                Text("Shows each author's portrait on the cards in the reading margins — the letters this one links to and the letters that link back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Reading: how EPUBs are presented — the theme (background and text
/// colours), which follows light and dark mode.
private struct ReadingSettingsView: View {
    @AppStorage(AppSettings.readerThemeKey)
    private var readerTheme = ReaderTheme.highContrast.rawValue
    @AppStorage(AppSettings.readerBodyFontKey)
    private var bodyFont = ReaderStyle.defaultBodyFont
    @AppStorage(AppSettings.readerHeadingFontKey)
    private var headingFont = ReaderStyle.defaultHeadingFont
    /// How citations read in a document — as written, numbered, or
    /// superscript. Applies live to whatever is open; the citation's
    /// click is the same in every style. (As in Knowledge Space.)
    @AppStorage("origamiCitationStyle")
    private var citationStyleRaw = OrigamiCitationStyle.authorDate.rawValue
    /// Whether citation cards may ask the scholarly services for what
    /// the package left out — see CitationLookup.swift.
    @AppStorage(CitationLookup.enabledKey) private var lookupCitedWorks = true
    @AppStorage(CitationLookup.openAlexKeyKey) private var openAlexKey = ""

    private let families = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $readerTheme) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Theme")
            } footer: {
                Text("The page's background and text colours when reading an EPUB. Text colour applies to headings too; themes follow light and dark mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Citations", selection: $citationStyleRaw) {
                    ForEach(OrigamiCitationStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Citations")
            } footer: {
                Text("How citations read in the native reading styles: (Hegland 2025) as the author wrote them, [3] as the source's reference list numbers them, or the number raised. The click is the same in every style — the source's card. The Faithful view shows the page exactly as published.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Look up cited works online", isOn: $lookupCitedWorks)
                TextField("OpenAlex API key (optional)", text: $openAlexKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!lookupCitedWorks)
            } header: {
                Text("Cited Works")
            } footer: {
                Text("When a citation's card lacks an abstract, the app asks Crossref and Semantic Scholar (both free, no account) and shows what they know — abstract, TL;DR, venue, DOI, an open-access link — naming the source. Answers are kept on this Mac, so a work is looked up once. OpenAlex has the widest abstract coverage but requires a free API key (openalex.org/settings/api); paste one to put it first in line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Body", selection: $bodyFont) {
                    ForEach(families, id: \.self) { family in
                        Text(family).font(.custom(family, size: 13)).tag(family)
                    }
                }
                Picker("Headings", selection: $headingFont) {
                    ForEach(families, id: \.self) { family in
                        Text(family).font(.custom(family, size: 13)).tag(family)
                    }
                }
                Button("Reset to Times / Georgia") {
                    bodyFont = ReaderStyle.defaultBodyFont
                    headingFont = ReaderStyle.defaultHeadingFont
                }
            } header: {
                Text("Fonts")
            } footer: {
                Text("Any font installed on this Mac, used everywhere words render — every reading style, the document views, the cards and columns. Defaults are Times for body and Georgia for headings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Who is writing: used as the default author of new documents and in the
/// Visual-Meta self-citation of exported documents.
private struct AuthorSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @AppStorage(AppSettings.authorNameKey) private var name = ""
    @AppStorage(AppSettings.authorTitleKey) private var title = ""
    @AppStorage(AppSettings.authorORCIDKey) private var orcid = ""
    @AppStorage(AppSettings.authorAffiliationKey) private var affiliation = ""
    @AppStorage(AppSettings.portraitStyleKey) private var portraitStyle = PortraitStyle.illustration.rawValue
    @AppStorage(AppSettings.portraitPromptKey) private var portraitPrompt = PortraitStyle.defaultConcept
    @State private var muteName = ""

    private var portraitsFooter: String {
        if !supportsImagePlayground {
            "Cartoon portraits need Apple Intelligence, which is not available on this Mac. Photos added to contact records are shown as-is."
        } else if !model.portraits.supportsAutomaticGeneration {
            "This Mac only allows cartoon portraits through the Image Playground window, so each is drawn from the contact record — this style and prompt are pre-set there. The original photos are never altered."
        } else {
            "Photos added to a contact record are turned into cartoon portraits, drawn on this Mac by Apple's Image Playground using this style and prompt. Changing the style re-draws every portrait from its original photo — the photos themselves are never altered."
        }
    }

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
                Picker("Cartoon style", selection: $portraitStyle) {
                    ForEach(PortraitStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
                .onChange(of: portraitStyle) {
                    model.portraits.restyleAllPortraits()
                }
                TextField("Portrait prompt", text: $portraitPrompt, axis: .vertical)
                    .lineLimit(2...4)
                if portraitPrompt != PortraitStyle.defaultConcept {
                    Button("Reset Prompt to Default") {
                        portraitPrompt = PortraitStyle.defaultConcept
                    }
                }
                if model.portraits.isRestyling {
                    ProgressView(value: Double(model.portraits.restyleDone),
                                 total: Double(max(model.portraits.restyleTotal, 1))) {
                        Text("Re-drawing portraits… \(model.portraits.restyleDone) of \(model.portraits.restyleTotal)")
                            .font(.caption)
                    }
                } else if model.portraits.supportsAutomaticGeneration {
                    Button("Redo All Portraits") {
                        model.portraits.restyleAllPortraits()
                    }
                }
            } header: {
                Text("Contact Portraits")
            } footer: {
                Text(portraitsFooter)
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
    @AppStorage(AppSettings.aiPersonProfilePromptKey) private var personProfilePrompt = AuthorProfiles.defaultPrompt
    @AppStorage(AppSettings.aiStrangerChallengePromptKey) private var strangerChallengePrompt = Stranger.defaultChallengePrompt
    @AppStorage(AppSettings.aiStrangerSupportPromptKey) private var strangerSupportPrompt = Stranger.defaultSupportPrompt
    @AppStorage(AppSettings.aiPersonProfilesEnabledKey) private var personProfilesEnabled = true
    @State private var selection = "AI Insights"

    private var prompt: Binding<String> {
        switch selection {
        case "Themes": $themesPrompt
        case "Open Questions": $questionsPrompt
        case "Agreements": $agreementsPrompt
        case "Disagreements": $disagreementsPrompt
        case "Person Profiles": $personProfilePrompt
        case "The Stranger — Challenge": $strangerChallengePrompt
        case "The Stranger — Support": $strangerSupportPrompt
        default: $insightsPrompt
        }
    }

    private var defaultValue: String {
        switch selection {
        case "Themes": Themes.defaultPrompt
        case "Open Questions": OpenQuestions.defaultPrompt
        case "Agreements": Agreements.defaultPrompt
        case "Disagreements": Disagreements.defaultPrompt
        case "Person Profiles": AuthorProfiles.defaultPrompt
        case "The Stranger — Challenge": Stranger.defaultChallengePrompt
        case "The Stranger — Support": Stranger.defaultSupportPrompt
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
        case "Person Profiles":
            "Revises one person's profile from their new letters and statements — interests, concerns, temperament, way of writing. Runs continually as letters arrive, when enabled below."
        case "The Stranger — Challenge":
            "The Stranger in challenge mode: names what the community believes together but has never defended, with the strongest honest case against. Every finding is grounded in real document addresses or dropped."
        case "The Stranger — Support":
            "The Stranger in support mode: names what the community has right but undervalues. Every finding is grounded in real document addresses or dropped."
        default:
            "The AI Insights report. Citing documents by bracketed address makes the model's references live links."
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Prompt", selection: $selection) {
                    ForEach(["AI Insights", "Themes", "Open Questions", "Agreements",
                             "Disagreements", "Person Profiles",
                             "The Stranger — Challenge", "The Stranger — Support"], id: \.self) {
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
            Section {
                Toggle("Build person profiles continually", isOn: $personProfilesEnabled)
            } footer: {
                Text("As letters and transcripts arrive, the on-device model revises a profile of each author — interests, concerns, temperament, way of writing — shown on their card and page, and available to views. Each document is read once; nothing leaves this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Views are exchangeable modules — this tab explains how to write and
/// share one, and lists what's installed, each with a checkbox for
/// whether it shows on the sidebar.
private struct ModulesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var xcodeExportID = LibraryViewRegistry.modules.first?.id ?? ""
    @State private var origamiExportID = LibraryViewRegistry.modules.first?.id ?? ""
    @State private var importedModules = ModuleExchange.importedArchives()
    @State private var shareNote: String?
    @State private var showsCreateGuide = false

    var body: some View {
        Form {
            Section {
                Text("Every view in the sidebar's Views section is a module: one Swift file anyone can write, share, and install. Views are how a community grows its own ways of seeing — the documents stay the same; the ways of looking multiply.")
                    .font(.callout)
            }
            Section {
                // A fixed window of about five rows; the rest scroll.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(LibraryViewRegistry.modules) { module in
                            HStack {
                                Toggle(isOn: shown(module.id)) {
                                    Label(module.name, systemImage: module.systemImage)
                                }
                                .toggleStyle(.checkbox)
                                Spacer()
                                Text(module.id)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            if module.id != LibraryViewRegistry.modules.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: 145)
            } header: {
                Text("Installed Views")
            } footer: {
                Text("Checked views appear in the sidebar's Views section; unchecking hides a view without uninstalling it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            shareSection
            if !importedModules.isEmpty {
                importedSection
            }
            Section {
                Button("Create Your Own…") { showsCreateGuide = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsCreateGuide) { createGuide }
    }

    /// Checked means on the sidebar.
    private func shown(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !model.isViewHidden(id) },
            set: { model.setView(id, hidden: !$0) }
        )
    }

    /// The module-writing recipe, shown on request rather than crowding
    /// the settings pane.
    private var createGuide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Your Own View")
                .font(.headline)
            Text("""
            1.  Write a SwiftUI view in one file. Read the library through the environment model — the document index, backlinks, and the ready-made derivations in LibraryInsights. Navigate with the same calls every view uses: openInLibrary, open(doc, fragment:), openTranspointing.
            2.  At the bottom of the file, declare a LibraryViewModule: an id, a sidebar name, an SF Symbol, and how to build its panes.
            3.  Add that module to LibraryViewRegistry.modules — one line. The sidebar entry, selection, and routing follow automatically.

            To share a view, send the file. To install one, drop it into the project and add its registry line. The full contract is documented in LibraryViewModule.swift.
            """)
            .font(.callout)
            HStack {
                Button("Copy Starter Module") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(Self.starterTemplate, forType: .string)
                }
                .help("Puts a compilable starter view module on the clipboard")
                Spacer()
                Button("Done") { showsCreateGuide = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Sharing: a module leaves as a Swift file (for another user's Xcode
    /// project) or as a .origamiview archive (for another user's Origami
    /// Text), and either kind imports back here.
    @ViewBuilder private var shareSection: some View {
        Section {
            Picker("For Xcode", selection: $xcodeExportID) {
                ForEach(LibraryViewRegistry.modules) { module in
                    Text(module.name).tag(module.id)
                }
            }
            Button("Export Swift File…") {
                export(id: xcodeExportID, asSwift: true)
            }
            Divider()
            Picker("For Origami Text", selection: $origamiExportID) {
                ForEach(LibraryViewRegistry.modules) { module in
                    Text(module.name).tag(module.id)
                }
            }
            Button("Export Origami View Module…") {
                export(id: origamiExportID, asSwift: false)
            }
            Divider()
            Button("Import Module…") { importModule() }
            if let shareNote {
                Text(shareNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Share")
        } footer: {
            Text("A Swift file goes into another user's Xcode project (plus one registry line). A .origamiview file imports straight into Origami Text: a module this build already contains becomes shareable from here; a new one is kept ready for its pass through Xcode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Modules brought in with Import: running if this build contains
    /// their code, otherwise held with their source ready to export.
    private var importedSection: some View {
        Section("Imported Modules") {
            ForEach(importedModules) { archive in
                LabeledContent {
                    HStack(spacing: 10) {
                        Text(ModuleExchange.isActive(archive) ? "Active" : "Awaiting build")
                            .font(.caption)
                            .foregroundStyle(ModuleExchange.isActive(archive)
                                             ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                        Button("Export Swift File…") {
                            ModuleExchange.exportSwiftFile(archive)
                        }
                        .controlSize(.small)
                        Button(role: .destructive) {
                            ModuleExchange.removeImported(archive)
                            importedModules = ModuleExchange.importedArchives()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                    }
                } label: {
                    Label(archive.name, systemImage: archive.systemImage)
                }
            }
        }
    }

    private func export(id: String, asSwift: Bool) {
        guard let module = LibraryViewRegistry.module(id: id) else { return }
        guard let archive = ModuleExchange.archive(for: module) else {
            shareNote = "No source is available for “\(module.name)” in this build — regenerate ModuleSources.json."
            return
        }
        shareNote = nil
        if asSwift {
            ModuleExchange.exportSwiftFile(archive)
        } else {
            ModuleExchange.exportOrigamiView(archive)
        }
    }

    private func importModule() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ModuleExchange.origamiViewType, .swiftSource]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .origamiview module or a Swift view-module file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let archive = try ModuleExchange.importModule(at: url)
            importedModules = ModuleExchange.importedArchives()
            shareNote = ModuleExchange.isActive(archive)
                ? "“\(archive.name)” imported — its view is part of this build and running."
                : "“\(archive.name)” imported — a new module runs after its Swift file is added to the Xcode project (export it from the list below)."
        } catch {
            shareNote = error.localizedDescription
        }
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
/// the account of what has been built — bundled with the app and opened
/// from here. This is the open-source doorway: everything needed to
/// build a compatible app, in two Markdown files.
private struct OpenSourceSettingsView: View {
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
                Text("The complete .origamitext specification, self-contained, and the account of what Origami Text does and why. Both open in your default Markdown app. Together they should be enough for your own AI, in a coding environment such as Xcode, to produce an app such as this — apart from the community's views, which travel as modules.")
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
                HStack {
                    Button("Choose Community Folder…") { model.chooseFolder() }
                    Button("Rescan for EPUBs") { model.scanCommunityFolderForEPUBs() }
                        .disabled(model.index.folderURL == nil)
                }
            } footer: {
                Text("The shared folder your community publishes EPUBs into — typically an iCloud folder. EPUBs found here appear in the Files list (unread ones in bold). New exports and iCloud downloads are picked up automatically; use Rescan if one has not appeared yet.")
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
    @AppStorage(AppSettings.verifyCrossrefKey) private var verifyCrossref = true

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
                Toggle("Verify references with Crossref", isOn: $verifyCrossref)
            } header: {
                Text("Reference verification")
            } footer: {
                Text("Preflight checks each reference before export against these services and shows what they return so you can correct titles, authors, years, and DOIs. Crossref is a free scholarly metadata service (api.crossref.org); queries send only the reference's title and authors.")
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
