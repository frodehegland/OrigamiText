import SwiftUI
import FoundationModels

/// Basic draft editor: title and author fields plus a plain-text body where
/// each line is a paragraph and #/##/### prefixes mark headings.
struct DraftEditorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var editor: DraftEditor
    @AppStorage(AppSettings.hideHeadingMarkersKey) private var hideHeadingMarkers = true
    @AppStorage(AppSettings.fullScreenContentWidthKey) private var fullScreenContentWidth = 760.0
    @FocusState private var titleFocused: Bool
    /// Tab in the title hands the keyboard straight to the body text,
    /// skipping the name-and-date line.
    @State private var bodyClaimsFocus = false
    @State private var titleSelection: TextSelection?
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var showNewAttention = false
    @State private var showAttentionPopover = false
    @State private var showDatePopover = false
    @State private var contactPerson: Person?
    @State private var showOnBehalfPopover = false
    @State private var onBehalfDraft = ""
    @State private var isSuggestingTitle = false
    /// Summary & Notes for a transcript draft — the same engine as the
    /// reading view, saved as a linked draft of its own; the note chips
    /// scroll the editor to the statements that produced them.
    @State private var transcriptSummary: TranscriptSummary?
    @State private var transcriptSummaryDoc: LiquidDoc?
    @State private var isSummarizing = false
    @State private var summaryProgress = ""
    @State private var summaryError: String?
    @State private var revealStatementLine: Int?

    /// No title worth keeping: empty, or the untouched "Untitled".
    private var titleIsUnset: Bool {
        let trimmed = editor.title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "Untitled"
    }

    private var suggestAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// One ask of the on-device model; the reply is trimmed to a single
    /// clean line and becomes the title.
    private func suggestTitle() {
        let text = String(editor.bodyText.prefix(4000))
        isSuggestingTitle = true
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(
                    to: "Generate a title for this text. Reply with the title alone.\n\n\(text)")
                let title = response.content
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’.")) ?? ""
                if !title.isEmpty {
                    editor.title = title
                } else {
                    model.showNote("The model offered no title.")
                }
            } catch {
                model.showNote("Could not suggest a title: \(error.localizedDescription)")
            }
            isSuggestingTitle = false
        }
    }

    /// The column beside a transcript draft, in the reading view's
    /// language: Action (publish and archive), then Summary & Notes.
    private var draftOptionsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                draftColumnSection("Action") {
                    Button {
                        model.exportDraft()
                    } label: {
                        Text("Publish…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Export as .origamitext — the draft retires and the published copy joins the record (⇧⌘E)")
                    Button {
                        model.archiveDraft(editor.original)
                    } label: {
                        Text("Archive")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Shelve this draft — it leaves Drafts for Archived, keeps its address, and can be un-archived any time")
                }
                draftColumnSection("Summary & Notes") {
                    Button {
                        runTranscriptSummary()
                    } label: {
                        HStack {
                            Text(transcriptSummary == nil ? "Summarize" : "Redo Summary")
                            if isSummarizing {
                                Spacer(minLength: 4)
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isSummarizing || !TranscriptSummarizer.isAvailable)
                    .help(TranscriptSummarizer.isAvailable
                          ? "Summarize this transcript on this Mac — every note links back to the statements that produced it; the summary is saved as a linked draft of its own"
                          : "Requires Apple Intelligence")
                    if isSummarizing, !summaryProgress.isEmpty {
                        Text(summaryProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let summaryError {
                        Text(summaryError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if transcriptSummary != nil, !isSummarizing {
                        Button("Remove Summary") {
                            if let transcriptSummaryDoc {
                                model.removeTranscriptSummary(transcriptSummaryDoc)
                            }
                            withAnimation(.snappy) {
                                transcriptSummary = nil
                                transcriptSummaryDoc = nil
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Trash the summary draft — the transcript itself is untouched")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A titled run of the column, the reading view's section style.
    private func draftColumnSection(_ title: String,
                                    @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    /// The draft transcript's linked summary, read back for display.
    private func loadTranscriptSummary() {
        if TranscriptSummarizer.canSummarize(editor.original),
           let summaryDoc = model.transcriptSummaryDocument(for: editor.original) {
            transcriptSummaryDoc = summaryDoc
            transcriptSummary = TranscriptSummary.display(from: summaryDoc,
                                                          transcriptID: editor.docID)
        } else {
            transcriptSummaryDoc = nil
            transcriptSummary = nil
        }
    }

    /// One read of the transcript draft. It is saved first, so the
    /// statement ids the notes cite match the text on screen; the
    /// summary lands in Drafts as a linked document of its own.
    private func runTranscriptSummary() {
        guard !isSummarizing else { return }
        model.saveDraftIfNeeded()
        let doc = editor.buildDocument()
        let docID = editor.docID
        isSummarizing = true
        summaryError = nil
        summaryProgress = ""
        Task {
            do {
                let summary = try await TranscriptSummarizer.summarize(doc) { note in
                    summaryProgress = note
                }
                let saved = model.saveTranscriptSummary(summary, for: doc)
                if editor.docID == docID {
                    withAnimation(.snappy) {
                        transcriptSummary = summary
                        transcriptSummaryDoc = saved
                    }
                }
            } catch is CancellationError {
            } catch {
                if editor.docID == docID {
                    summaryError = error.localizedDescription
                }
            }
            if editor.docID == docID {
                isSummarizing = false
                summaryProgress = ""
            }
        }
    }

    /// The summary as it reads above the transcript's text: the
    /// overview, then the notes, each chip scrolling the editor to the
    /// statement that produced it.
    private func transcriptSummaryPanel(_ summary: TranscriptSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let overview = summary.overview {
                    Text(overview)
                        .font(.system(size: 14, design: .serif))
                        .textSelection(.enabled)
                }
                ForEach(summary.notes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.text)
                                .font(.system(size: 13, design: .serif))
                                .textSelection(.enabled)
                            WrappingHStack(horizontalSpacing: 5, verticalSpacing: 4) {
                                ForEach(note.sources, id: \.self) { source in
                                    summarySourceChip(source)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    /// One doorway back into the conversation: the speaker's name,
    /// scrolling the editor to (and flashing) the statement.
    private func summarySourceChip(_ paragraphID: String) -> some View {
        let speaker = (editor.original.body ?? [])
            .first { $0.id == paragraphID }?.speaker
        return Button {
            // Paragraph ids number the non-empty lines: pN is line N.
            if let line = Int(paragraphID.dropFirst()) {
                revealStatementLine = line
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 7))
                Text(speaker ?? "statement")
            }
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Scroll to the statement this note came from")
    }

    /// The draft's speakers in order of first appearance (transcripts).
    private var speakers: [String] {
        var seen: Set<String> = []
        return (editor.original.body ?? []).compactMap { paragraph in
            guard let speaker = paragraph.speaker, seen.insert(speaker).inserted else { return nil }
            return speaker
        }
    }

    /// Declaring whose words this document carries — the author stays the
    /// one who prepares and stands by it, per the export convention.
    private var onBehalfPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On Behalf Of")
                .font(.headline)
            Text("The author remains \(editor.author); the document declares whose words it carries — an email pasted in, a statement prepared for someone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $onBehalfDraft)
                .textFieldStyle(.roundedBorder)
            if !model.topCorrespondents.isEmpty {
                HStack(spacing: 4) {
                    ForEach(model.topCorrespondents.prefix(4), id: \.self) { name in
                        Button(name) { onBehalfDraft = name }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
            }
            HStack {
                Button("Cancel") { showOnBehalfPopover = false }
                Spacer()
                Button("Set") {
                    let trimmed = onBehalfDraft.trimmingCharacters(in: .whitespaces)
                    editor.onBehalfOf = trimmed.isEmpty ? nil : trimmed
                    showOnBehalfPopover = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(onBehalfDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// The names on offer for attention: the ranked correspondents first,
    /// then everyone else the library knows — every author and every
    /// People record, alphabetically — plus anyone already addressed, so
    /// every choice stays visible and uncheckable.
    private var attentionCandidates: [String] {
        var names = model.topCorrespondents
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !model.authorIdentity.matches(author: trimmed),
                  !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { return }
            names.append(trimmed)
        }
        for summary in model.authorSummaries.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            add(summary.name)
        }
        for name in editor.attention
        where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        return names
    }

    private func attentionChecked(_ name: String) -> Binding<Bool> {
        Binding(
            get: { editor.attention.contains { $0.caseInsensitiveCompare(name) == .orderedSame } },
            set: { checked in
                if checked {
                    editor.addAttention(name)
                } else {
                    editor.attention.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
                }
            })
    }

    /// Addressing the document: check every reader it is for — several at
    /// once — and "New…" for a name the community does not know yet.
    private var attentionPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For the Attention Of")
                .font(.headline)
            Text("Address this document for their attention — readable by anyone, and recorded in its Visual-Meta.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The whole community can be long; the list scrolls past
            // about a dozen rows rather than outgrowing the screen.
            let candidates = attentionCandidates
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(candidates, id: \.self) { name in
                        Toggle(name, isOn: attentionChecked(name))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: min(CGFloat(max(candidates.count, 1)) * 24, 290))
            if !candidates.isEmpty {
                Divider()
            }
            Button("New…") {
                showAttentionPopover = false
                showNewAttention = true
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var isTranscriptDraft: Bool {
        TranscriptSummarizer.canSummarize(editor.original)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            editorColumn
            // A transcript draft carries its options beside the text,
            // as the reading view does — the same column language, the
            // editing acts.
            if isTranscriptDraft {
                Divider()
                draftOptionsColumn
            }
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField("Title", text: $editor.title, selection: $titleSelection)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, design: .serif))
                        .focused($titleFocused)
                        .onKeyPress(.tab) {
                            // Straight from the title into the words; the
                            // name-and-date line stays click-editable.
                            titleFocused = false
                            bodyClaimsFocus = true
                            return .handled
                        }
                    // Pasted text, no title yet: the on-device model can
                    // offer one. The button leaves once a title exists.
                    if titleIsUnset && !editor.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isSuggestingTitle {
                            ProgressView()
                                .controlSize(.small)
                        } else if suggestAvailable {
                            Button("Suggest") { suggestTitle() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Have the on-device model suggest a title from the text — nothing leaves this Mac")
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("Author", text: $editor.author)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 220)
                    // Provenance by hand: pasted email text and other
                    // borrowed words can be declared here — the same
                    // convention lifting and export follow. A separate
                    // button, because right-clicking a text field summons
                    // the system's edit menu, never a custom one.
                    Menu {
                        Button(editor.onBehalfOf == nil
                               ? "On Behalf Of…" : "Change “On Behalf Of”…") {
                            onBehalfDraft = editor.onBehalfOf ?? ""
                            showOnBehalfPopover = true
                        }
                        if editor.onBehalfOf != nil {
                            Button("Remove “On Behalf Of”") {
                                editor.onBehalfOf = nil
                            }
                        }
                    } label: {
                        Image(systemName: "person.line.dotted.person")
                            .font(.system(size: 10))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Declare whose words this document carries — “on behalf of”, as at export")
                    .popover(isPresented: $showOnBehalfPopover, arrowEdge: .bottom) {
                        onBehalfPopover
                    }
                    // A draft carrying someone else's words says so, here
                    // as well as at export — provenance is never a surprise.
                    if let onBehalfOf = editor.onBehalfOf {
                        Text("on behalf of \(onBehalfOf)")
                            .help("This document carries \(onBehalfOf)’s words; exporting declares it")
                            .contextMenu {
                                Button("Change “On Behalf Of”…") {
                                    onBehalfDraft = onBehalfOf
                                    showOnBehalfPopover = true
                                }
                                Button("Remove “On Behalf Of”") {
                                    editor.onBehalfOf = nil
                                }
                            }
                    }
                    Text("·")
                    Button {
                        showDatePopover = true
                    } label: {
                        HStack(spacing: 3) {
                            Text(editor.date?.displayText ?? editor.createdText)
                            if editor.date != nil {
                                Image(systemName: "calendar")
                                    .font(.system(size: 9))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(editor.date == nil
                          ? "Click to date this document — a meeting written up the next day can carry the meeting's date"
                          : "Dated \(editor.date?.displayText ?? "") · created \(editor.createdText). Click to change.")
                    .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                        DateAssignmentPopover(date: $editor.date, created: editor.original.created)
                    }
                    Text("·")
                    Button {
                        showAttentionPopover = true
                    } label: {
                        HStack(spacing: 3) {
                            Text("Attention of")
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Address this document for someone's attention — readable by anyone, and recorded in its Visual-Meta")
                    .popover(isPresented: $showAttentionPopover, arrowEdge: .bottom) {
                        attentionPopover
                    }
                    ForEach(editor.attention, id: \.self) { name in
                        Button {
                            editor.removeAttention(name)
                        } label: {
                            HStack(spacing: 3) {
                                Text(name)
                                Image(systemName: "xmark")
                                    .font(.system(size: 7))
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(name)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .sheet(isPresented: $showNewAttention) {
                    PersonFormView(person: Person(), heading: "For the attention of") { person in
                        model.people.upsert(person)
                        editor.addAttention(person.displayName)
                    }
                }
                // A transcript's speakers, visible as people the system
                // knows: click one for their page, their contact record,
                // or to add them to People.
                if !speakers.isEmpty {
                    HStack(spacing: 6) {
                        Text("Speakers:")
                        ForEach(speakers, id: \.self) { name in
                            Menu {
                                Button("Profile") { model.openAuthorPage(named: name) }
                                if let known = model.people.person(named: name) {
                                    Button("Contact Record…") { contactPerson = known }
                                } else {
                                    Button("Add \(name) to People…") { contactPerson = Person(displayName: name) }
                                    // The transcript may spell a name its
                                    // own way — "Frode H." is still Frode.
                                    // Associating stores the spelling as an
                                    // alias on the record, so this name
                                    // resolves everywhere from now on.
                                    if !model.people.people.isEmpty {
                                        Menu("Associate with Record") {
                                            ForEach(model.people.people.sorted {
                                                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                                            }) { person in
                                                Button(person.displayName) {
                                                    model.people.associate(alias: name, with: person)
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(name)
                                    if model.people.person(named: name) == nil {
                                        Image(systemName: "person.badge.plus")
                                            .font(.system(size: 9))
                                    }
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .contentShape(Capsule())
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help(model.people.person(named: name) == nil
                                  ? "\(name) spoke in this meeting and is not yet in People"
                                  : "\(name) spoke in this meeting")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .sheet(item: $contactPerson) { person in
                        PersonFormView(person: person, heading: "Contact Record") { updated in
                            model.people.upsert(updated)
                        }
                    }
                }
                // The transcript's summary, above the words it
                // summarizes — its controls live in the column.
                if isTranscriptDraft, let summary = transcriptSummary {
                    transcriptSummaryPanel(summary)
                }
                Divider()
            }
            .padding([.horizontal, .top], 24)

            MarkdownTextEditor(text: $editor.bodyText,
                               hideHeadingMarkers: hideHeadingMarkers,
                               onReference: { address, bibtex in
                                   editor.registerReference(address: address, bibtex: bibtex)
                               },
                               speakers: speakers,
                               onLiftStatement: { paragraphText in
                                   model.liftStatement(fromDraftParagraph: paragraphText)
                               },
                               contextDoc: { editor.buildDocument() },
                               contextMenuItems: { target in
                                   ContextActionBuilder.menuItems(for: target, mode: .editing,
                                                                  model: model)
                               },
                               claimFocus: $bodyClaimsFocus,
                               revealParagraph: $revealStatementLine)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)

            Divider()
            Text("One paragraph per line. Start a line with #, ##, or ### for a heading.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            // Transcript drafts archive from their options column.
            if !isTranscriptDraft {
                Button("Archive") { model.archiveDraft(editor.original) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Shelve this draft — it leaves Drafts for Archived, keeps its address, and can be un-archived any time")
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 8)
            }
        }
        // Full screen is a focus mode: keep the writing at a readable measure.
        .frame(maxWidth: model.isFullScreen ? CGFloat(fullScreenContentWidth) : .infinity)
        .frame(maxWidth: .infinity)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.saveDraft()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!editor.hasUnsavedChanges)
                .help("Save (⌘S)")

                Button {
                    model.exportDraft()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Export as .origamitext for sharing (⇧⌘E)")
            }
        }
        .onChange(of: editor.docID) {
            isSummarizing = false
            summaryProgress = ""
            summaryError = nil
            loadTranscriptSummary()
        }
        .onAppear {
            loadTranscriptSummary()
            // A fresh document opens with "Untitled" pre-selected: type to
            // replace it, or tab past to keep it.
            guard editor.title == "Untitled" else { return }
            titleFocused = true
            Task {
                // Let focus land before selecting, so the selection sticks.
                try? await Task.sleep(for: .milliseconds(60))
                titleSelection = TextSelection(range: editor.title.startIndex..<editor.title.endIndex)
            }
        }
        // The typed title is saved immediately: shortly after typing pauses,
        // and the moment focus leaves the title field.
        .onChange(of: editor.title) {
            titleSaveTask?.cancel()
            titleSaveTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                model.saveDraftIfNeeded()
            }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { model.saveDraftIfNeeded() }
        }
        .onDisappear { model.saveDraftIfNeeded() }
    }
}

/// Assigns the document's human date — yesterday's meeting, or 329 BCE.
/// The creation timestamp is untouched; it remains what the id derives
/// from, and "Use Creation Date" returns to it.
private struct DateAssignmentPopover: View {
    @Binding var date: LiquidDate?
    let created: Date
    @Environment(\.dismiss) private var dismiss

    private enum Precision: String, CaseIterable {
        case day = "Day", month = "Month", year = "Year"
    }
    @State private var precision: Precision = .day
    @State private var yearText = ""
    @State private var isBCE = false
    @State private var month = 1
    @State private var day = 1

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    private var composed: LiquidDate? {
        guard let year = Int(yearText.trimmingCharacters(in: .whitespaces)), year > 0 else { return nil }
        return LiquidDate(displayYear: year, isBCE: isBCE,
                          month: precision == .year ? nil : month,
                          day: precision == .day ? day : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Document Date")
                .font(.headline)

            Picker("Precision", selection: $precision) {
                ForEach(Precision.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                if precision == .day {
                    Picker("Day", selection: $day) {
                        ForEach(1...31, id: \.self) { Text("\($0)") }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if precision != .year {
                    Picker("Month", selection: $month) {
                        ForEach(1...12, id: \.self) { Text(Self.monthNames[$0 - 1]).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                TextField("Year", text: $yearText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Picker("Era", selection: $isBCE) {
                    Text("CE").tag(false)
                    Text("BCE").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if let composed {
                Text("This document will be listed as \(composed.displayText).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enter a year.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Use Creation Date") {
                    date = nil
                    dismiss()
                }
                .help("Remove the assigned date; the document goes by \(created.formatted(date: .abbreviated, time: .omitted)) again")
                Spacer()
                Button("Set Date") {
                    date = composed
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(composed == nil)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear(perform: seed)
    }

    /// Starts from the assigned date if there is one, else the creation day.
    private func seed() {
        if let date {
            isBCE = date.isBCE
            yearText = String(date.displayYear)
            month = date.month ?? 1
            day = date.day ?? 1
            precision = date.day != nil ? .day : (date.month != nil ? .month : .year)
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let parts = calendar.dateComponents([.year, .month, .day], from: created)
            isBCE = false
            yearText = String(parts.year ?? 2026)
            month = parts.month ?? 1
            day = parts.day ?? 1
            precision = .day
        }
    }
}
