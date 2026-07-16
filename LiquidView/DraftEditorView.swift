import SwiftUI

/// Basic draft editor: title and author fields plus a plain-text body where
/// each line is a paragraph and #/##/### prefixes mark headings.
struct DraftEditorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var editor: DraftEditor
    @AppStorage(AppSettings.hideHeadingMarkersKey) private var hideHeadingMarkers = true
    @AppStorage(AppSettings.fullScreenContentWidthKey) private var fullScreenContentWidth = 760.0
    @FocusState private var titleFocused: Bool
    @State private var titleSelection: TextSelection?
    @State private var titleSaveTask: Task<Void, Never>?
    @State private var showNewAttention = false
    @State private var showDatePopover = false
    @State private var contactPerson: Person?

    /// The draft's speakers in order of first appearance (transcripts).
    private var speakers: [String] {
        var seen: Set<String> = []
        return (editor.original.body ?? []).compactMap { paragraph in
            guard let speaker = paragraph.speaker, seen.insert(speaker).inserted else { return nil }
            return speaker
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $editor.title, selection: $titleSelection)
                    .textFieldStyle(.plain)
                    .font(.system(size: 28, design: .serif))
                    .focused($titleFocused)
                HStack(spacing: 6) {
                    TextField("Author", text: $editor.author)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 220)
                    // A lifted draft says whose words it carries, here as
                    // well as at export — provenance is never a surprise.
                    if let onBehalfOf = editor.original.onBehalfOf {
                        Text("on behalf of \(onBehalfOf)")
                            .help("This draft carries \(onBehalfOf)’s words, lifted from a transcript; exporting declares it")
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
                    Menu("Attention of") {
                        ForEach(model.topCorrespondents, id: \.self) { name in
                            Button(name) { editor.addAttention(name) }
                        }
                        if !model.topCorrespondents.isEmpty {
                            Divider()
                        }
                        Button("New…") { showNewAttention = true }
                    }
                    .fixedSize()
                    .help("Address this document for someone's attention — readable by anyone, and recorded in its Visual-Meta")
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
                                Button("Everything by \(name)") { model.openAuthorPage(named: name) }
                                if let known = model.people.person(named: name) {
                                    Button("Contact Record…") { contactPerson = known }
                                } else {
                                    Button("Add \(name) to People…") { contactPerson = Person(displayName: name) }
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
                               })
                .padding(.horizontal, 4)
                .padding(.vertical, 4)

            Divider()
            Text("One paragraph per line. Start a line with #, ##, or ### for a heading.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            Button("Archive") { model.archiveDraft(editor.original) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Shelve this draft — it leaves Drafts for Archived, keeps its address, and can be un-archived any time")
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
        // Full screen is a focus mode: keep the writing at a readable measure.
        .frame(maxWidth: model.isFullScreen ? CGFloat(fullScreenContentWidth) : .infinity)
        .frame(maxWidth: .infinity)
        .navigationTitle(editor.title.isEmpty ? "Untitled" : editor.title)
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
        .onAppear {
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
