import SwiftUI
import UIKit
import FoundationModels

/// What a composer opens on: blank for New Letter, or seeded by the
/// reply family with a title, the discourse link it will carry, and the
/// original's author already down for attention.
struct LetterSeed: Identifiable {
    let id = UUID()
    var title: String = ""
    /// The discourse link a reply carries — responds-to, extends,
    /// supports, questions, disagrees-with, summarizes.
    var link: LiquidDoc.Link?
    /// The linked letter's title, for the banner under the title field.
    var linkedTitle: String?
    var attention: [String] = []
}

/// Writing a letter, with the Mac's conventions intact: one paragraph
/// per line; #, ##, ### headings styled as you type; pasted BibTeX
/// becoming a citation line whose record travels in the letter's
/// references; attention naming who it is for; "on behalf of" declaring
/// borrowed words; and a human date when the letter is about another
/// day. Publish writes it into the community folder — there are no
/// drafts on the phone; a letter is written and sent.
struct LetterComposerView: View {
    @Environment(LettersModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let seed: LetterSeed

    @State private var title = ""
    @State private var bodyText = ""
    @State private var attention: [String] = []
    @State private var onBehalfOf: String?
    @State private var date: LiquidDate?
    @State private var references: [(id: String, bibtex: String)] = []
    @State private var choosingAttention = false
    @State private var namingOnBehalf = false
    @State private var typedOnBehalf = ""
    @State private var choosingDate = false
    @State private var confirmingDiscard = false
    @State private var seeded = false
    /// Produced by AI on the author's behalf — the Mac declares this at
    /// export; the phone declares it here, before publishing.
    @State private var aiProduced = false
    @State private var isSuggestingTitle = false
    @State private var suggestNote: String?
    @FocusState private var titleFocused: Bool

    private var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// One ask of the on-device model, as on the Mac; the reply is
    /// trimmed to a single clean line and becomes the title.
    private func suggestTitle() {
        let text = String(bodyText.prefix(4000))
        isSuggestingTitle = true
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(
                    to: "Generate a title for this text. Reply with the title alone.\n\n\(text)")
                let suggested = response.content
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’.")) ?? ""
                if !suggested.isEmpty {
                    title = suggested
                } else {
                    suggestNote = "The model offered no title."
                }
            } catch {
                suggestNote = "Could not suggest a title: \(error.localizedDescription)"
            }
            isSuggestingTitle = false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField("Title", text: $title)
                        .font(.system(size: 24, design: .serif))
                        .focused($titleFocused)
                    // Pasted text, no title yet: the on-device model can
                    // offer one. The button leaves once a title exists.
                    if title.trimmingCharacters(in: .whitespaces).isEmpty
                        && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isSuggestingTitle {
                            ProgressView()
                                .controlSize(.small)
                        } else if suggestAvailable {
                            Button("Suggest") { suggestTitle() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                if let linkedTitle = seed.linkedTitle, let rel = seed.link?.rel,
                   let relation = DocumentRelation.from(rel: rel), let label = relation.bylineLabel {
                    Text("\(label) “\(linkedTitle)” — the connection travels with the letter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bylineBar
                // Provenance is never a surprise: an AI-produced letter
                // says so before it is published, as at export on the Mac.
                if aiProduced {
                    Text("Produced by AI on behalf of \(model.authorName) — declared in the letter and its Visual-Meta.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                MarkdownTextView(text: $bodyText) { id, bibtex in
                    if !references.contains(where: { $0.id == id }) {
                        references.append((id: id, bibtex: bibtex))
                    }
                }
                Text("One paragraph per line. Start a line with #, ##, or ### for a heading. Paste BibTeX and it becomes a citation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .navigationTitle("New Letter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isEmpty { dismiss() } else { confirmingDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") { publish() }
                        .fontWeight(.semibold)
                        .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Discard this letter?", isPresented: $confirmingDiscard) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Writing", role: .cancel) {}
            } message: {
                Text("There are no drafts on the phone — a letter is written and published.")
            }
            .sheet(isPresented: $choosingDate) {
                LetterDateSheet(date: $date)
            }
            .sheet(isPresented: $choosingAttention) {
                AttentionPickerSheet(knownNames: model.knownNames, attention: $attention) { name in
                    model.noteKnownName(name)
                }
            }
            .alert("On Behalf Of", isPresented: $namingOnBehalf) {
                TextField("Name", text: $typedOnBehalf)
                ForEach(model.knownNames, id: \.self) { name in
                    Button(name) { onBehalfOf = name }
                }
                Button("Set") {
                    let trimmed = typedOnBehalf.trimmingCharacters(in: .whitespaces)
                    onBehalfOf = trimmed.isEmpty ? nil : trimmed
                    if let onBehalfOf { model.noteKnownName(onBehalfOf) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The author remains \(model.authorName); the letter declares whose words it carries.")
            }
            .alert("Suggest a Title", isPresented: Binding(
                get: { suggestNote != nil },
                set: { if !$0 { suggestNote = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(suggestNote ?? "")
            }
            .onAppear(perform: seedOnce)
        }
    }

    private func seedOnce() {
        guard !seeded else { return }
        seeded = true
        title = seed.title
        attention = seed.attention
        titleFocused = seed.title.isEmpty
    }

    /// The line under the title, as on the Mac: name · date · attention
    /// — each a control.
    private var bylineBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let onBehalfOf {
                    Menu("\(model.authorName) on behalf of \(onBehalfOf)") {
                        Button("Change “On Behalf Of”…") {
                            typedOnBehalf = onBehalfOf
                            namingOnBehalf = true
                        }
                        Button("Remove “On Behalf Of”") { self.onBehalfOf = nil }
                        Divider()
                        Toggle("Produced by AI", isOn: $aiProduced)
                    }
                } else {
                    Menu(model.authorName) {
                        Button("On Behalf Of…") {
                            typedOnBehalf = ""
                            namingOnBehalf = true
                        }
                        Divider()
                        Toggle("Produced by AI", isOn: $aiProduced)
                    }
                }
                Text("·")
                Button {
                    choosingDate = true
                } label: {
                    Text(date?.displayText ?? Date.now.formatted(date: .abbreviated, time: .omitted))
                }
                Text("·")
                Button("Attention of") {
                    choosingAttention = true
                }
                ForEach(attention, id: \.self) { name in
                    Button {
                        attention.removeAll { $0 == name }
                    } label: {
                        HStack(spacing: 3) {
                            Text(name)
                            Image(systemName: "xmark")
                                .font(.system(size: 8))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func publish() {
        let published = model.publishLetter(
            title: title,
            bodyText: bodyText,
            attention: attention,
            onBehalfOf: onBehalfOf,
            aiProduced: aiProduced,
            date: date,
            extraLinks: seed.link.map { [$0] } ?? [],
            references: references)
        if published != nil { dismiss() }
        // On failure the composer stays open; the reason is in
        // model.lastError, shown by the home view's alert after dismiss —
        // so surface it here too.
    }
}

// MARK: - For the attention of

/// Addressing the letter: the community's names as a checklist — check
/// every reader it is for, several at once — and a field for a name the
/// folder does not know yet.
private struct AttentionPickerSheet: View {
    let knownNames: [String]
    @Binding var attention: [String]
    /// Called for a newly typed name, so it is offered again next time.
    var onNewName: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    /// The community's names, plus anyone already addressed who is not
    /// among them, so every choice stays visible and uncheckable.
    private var candidates: [String] {
        var names = knownNames
        for name in attention
        where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            names.append(name)
        }
        return names
    }

    private func isChosen(_ name: String) -> Bool {
        attention.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func toggle(_ name: String) {
        if isChosen(name) {
            attention.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            attention.append(name)
        }
    }

    private func addNew() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !isChosen(trimmed) { attention.append(trimmed) }
        onNewName(trimmed)
        newName = ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.self) { name in
                        Button {
                            toggle(name)
                        } label: {
                            HStack {
                                Text(name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isChosen(name) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Address this letter for their attention — readable by anyone, and recorded in its Visual-Meta.")
                }
                Section("New") {
                    HStack {
                        TextField("Name", text: $newName)
                            .onSubmit(addNew)
                        Button("Add") { addNew() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("For the Attention Of")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - The human date

/// Assigns the letter's human date — yesterday's meeting, or 329 BCE —
/// the Mac's date popover, sized for a phone. The creation timestamp is
/// untouched; "Use Creation Date" returns to it.
private struct LetterDateSheet: View {
    @Binding var date: LiquidDate?
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
        NavigationStack {
            Form {
                Picker("Precision", selection: $precision) {
                    ForEach(Precision.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                if precision == .day {
                    Picker("Day", selection: $day) {
                        ForEach(1...31, id: \.self) { Text("\($0)") }
                    }
                }
                if precision != .year {
                    Picker("Month", selection: $month) {
                        ForEach(1...12, id: \.self) { Text(Self.monthNames[$0 - 1]).tag($0) }
                    }
                }
                HStack {
                    TextField("Year", text: $yearText)
                        .keyboardType(.numberPad)
                    Picker("Era", selection: $isBCE) {
                        Text("CE").tag(false)
                        Text("BCE").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 140)
                }
                if let composed {
                    Text("This letter will be listed as \(composed.displayText).")
                        .foregroundStyle(.secondary)
                }
                Button("Use Creation Date") {
                    date = nil
                    dismiss()
                }
            }
            .navigationTitle("Letter Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set Date") {
                        date = composed
                        dismiss()
                    }
                    .disabled(composed == nil)
                }
            }
            .onAppear(perform: seedFields)
        }
        .presentationDetents([.medium])
    }

    private func seedFields() {
        if let date {
            isBCE = date.isBCE
            yearText = String(date.displayYear)
            month = date.month ?? 1
            day = date.day ?? 1
            precision = date.day != nil ? .day : (date.month != nil ? .month : .year)
        } else {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
            yearText = String(parts.year ?? 2026)
            month = parts.month ?? 1
            day = parts.day ?? 1
        }
    }
}

// MARK: - The writing area

/// The Mac's markdown editor, in UIKit: one paragraph per line, heading
/// lines sized and bolded as they are typed — attribute-only restyling,
/// so the cursor and undo stay put — and pasted BibTeX becoming a
/// citation line, its record reported for the letter's references.
private struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    /// Called for each pasted BibTeX entry: (citation identifier, raw entry).
    var onReference: (String, String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = Coordinator.bodyFont
        view.backgroundColor = .clear
        view.autocorrectionType = .default
        view.alwaysBounceVertical = true
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onReference = onReference
        if view.text != text {
            view.text = text
            context.coordinator.applyStyling(to: view)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var onReference: ((String, String) -> Void)?

        static let bodyFont = UIFont(descriptor: UIFont.systemFont(ofSize: 17)
            .fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: 17).fontDescriptor,
                                     size: 17)

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            applyStyling(to: textView)
        }

        /// Pasted BibTeX becomes citation lines, exactly as on the Mac;
        /// everything else passes through untouched.
        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            let entries = MiniBibTeX.parse(replacement)
            guard !entries.isEmpty else { return true }
            var transformed = entries.map(\.citationText).joined(separator: "\n\n")
            for entry in entries {
                onReference?(entry.referenceID, entry.raw)
            }
            if range.location > 0 {
                let existing = textView.text as NSString
                let previous = existing.character(at: range.location - 1)
                if let scalar = Unicode.Scalar(previous), !CharacterSet.newlines.contains(scalar) {
                    transformed = "\n\n" + transformed
                }
            }
            let current = textView.text as NSString
            textView.text = current.replacingCharacters(in: range, with: transformed)
            textView.selectedRange = NSRange(location: range.location + (transformed as NSString).length, length: 0)
            text.wrappedValue = textView.text
            applyStyling(to: textView)
            return false
        }

        /// Restyles the whole letter: body serif everywhere, heading
        /// lines sized and bolded by their markdown prefix. Attribute-only
        /// changes, so selection stays put.
        func applyStyling(to textView: UITextView) {
            let storage = textView.textStorage
            let full = NSRange(location: 0, length: storage.length)
            let selected = textView.selectedRange
            storage.beginEditing()
            storage.addAttribute(.font, value: Self.bodyFont, range: full)
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)
            let nsText = storage.string as NSString
            // The Mac's preference, honored here: heading markers are
            // invisible while their line is styled, or dimmed when shown.
            let hideMarkers = UserDefaults.standard.object(forKey: "hideHeadingMarkers") as? Bool ?? true
            var location = 0
            while location < nsText.length {
                let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
                let line = nsText.substring(with: lineRange)
                if let level = Self.headingLevel(for: line) {
                    storage.addAttribute(.font, value: Self.headingFont(level: level), range: lineRange)
                    let markerRange = NSRange(location: lineRange.location, length: level + 1)
                    if hideMarkers {
                        storage.addAttributes([
                            .font: Self.hiddenMarkerFont,
                            .foregroundColor: UIColor.clear,
                        ], range: markerRange)
                    } else {
                        storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel,
                                             range: markerRange)
                    }
                }
                location = NSMaxRange(lineRange)
                if location == 0 { break }
            }
            storage.endEditing()
            textView.selectedRange = selected
        }

        // Near-zero size collapses the marker's width so hidden markers
        // don't leave a gap in front of the heading.
        private static let hiddenMarkerFont = UIFont.systemFont(ofSize: 0.1)

        private static func headingLevel(for line: String) -> Int? {
            if line.hasPrefix("### ") { return 3 }
            if line.hasPrefix("## ") { return 2 }
            if line.hasPrefix("# ") { return 1 }
            return nil
        }

        private static func headingFont(level: Int) -> UIFont {
            let size: CGFloat
            let weight: UIFont.Weight
            switch level {
            case 1: size = 25; weight = .bold
            case 2: size = 22; weight = .bold
            default: size = 19; weight = .semibold
            }
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
        }
    }
}

// MARK: - BibTeX, minimally

/// The slice of the Mac's BibTeX support a paste needs, kept here
/// because BibTeX.swift is not a member of this target (membership is
/// managed in Xcode): entries are recognized, their key fields read,
/// and each becomes the same citation sentence the Mac writes —
/// “Title” (Author, Year) [address] — with the raw entry kept verbatim
/// for the letter's references.
private enum MiniBibTeX {

    struct Entry {
        let key: String
        let fields: [String: String]
        let raw: String

        var firstAuthor: String? {
            guard let raw = fields["author"] else { return nil }
            let first = raw.components(separatedBy: " and ").first ?? raw
            if first.contains(",") {
                let parts = first.split(separator: ",", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { return "\(parts[1]) \(parts[0])" }
            }
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        var hasMultipleAuthors: Bool {
            (fields["author"] ?? "").contains(" and ")
        }

        /// The deterministic library address, when the entry carries
        /// Visual-Meta identity (vm-id + author) — resolves now or when
        /// the document arrives; else the entry's own key.
        var derivedID: String? {
            guard let stamp = fields["vm-id"],
                  let created = LiquidDoc.parseISO8601(stamp),
                  let firstAuthor else { return nil }
            return LiquidAddress.makeID(author: firstAuthor, created: created)
        }

        var referenceID: String { derivedID ?? key }

        var externalURL: String? {
            if let doi = fields["doi"], !doi.isEmpty {
                return doi.hasPrefix("http") ? doi : "https://doi.org/\(doi)"
            }
            return fields["url"]
        }

        /// “Title” (Author, Year) [address] — the Mac's citation sentence.
        var citationText: String {
            var parts: [String] = []
            if let title = fields["title"] { parts.append("“\(title)”") }
            var credit: [String] = []
            if let firstAuthor { credit.append(hasMultipleAuthors ? "\(firstAuthor) et al." : firstAuthor) }
            if let year = fields["year"] { credit.append(year) }
            if !credit.isEmpty { parts.append("(\(credit.joined(separator: ", ")))") }
            if let derivedID {
                parts.append("[\(derivedID)]")
            } else if let externalURL {
                parts.append(externalURL)
            }
            return parts.joined(separator: " ")
        }
    }

    /// Parses one or more entries; [] for anything that isn't BibTeX,
    /// so ordinary pasting is never hijacked.
    static func parse(_ text: String) -> [Entry] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@") else { return [] }
        var entries: [Entry] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "@" else { index += 1; continue }
            let entryStart = index
            var cursor = index + 1
            var type = ""
            while cursor < characters.count, characters[cursor].isLetter {
                type.append(characters[cursor])
                cursor += 1
            }
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard !type.isEmpty, cursor < characters.count, characters[cursor] == "{" else {
                index += 1
                continue
            }
            cursor += 1
            var depth = 1
            var body = ""
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                body.append(character)
                cursor += 1
            }
            let entryEnd = min(cursor, characters.count - 1)
            let raw = String(characters[entryStart...entryEnd])
            if let entry = makeEntry(body: body, raw: raw) {
                entries.append(entry)
            }
            index = cursor + 1
        }
        return entries
    }

    private static func makeEntry(body: String, raw: String) -> Entry? {
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let key = body[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        var fields: [String: String] = [:]
        let rest = Array(body[body.index(after: comma)...])
        var cursor = 0
        while cursor < rest.count {
            // field = {value} | "value" | bare
            while cursor < rest.count, rest[cursor].isWhitespace || rest[cursor] == "," { cursor += 1 }
            var name = ""
            while cursor < rest.count, rest[cursor].isLetter || rest[cursor] == "-" {
                name.append(rest[cursor])
                cursor += 1
            }
            while cursor < rest.count, rest[cursor].isWhitespace { cursor += 1 }
            guard cursor < rest.count, rest[cursor] == "=" else { break }
            cursor += 1
            while cursor < rest.count, rest[cursor].isWhitespace { cursor += 1 }
            guard cursor < rest.count else { break }
            var value = ""
            if rest[cursor] == "{" {
                cursor += 1
                var depth = 1
                while cursor < rest.count {
                    if rest[cursor] == "{" { depth += 1 }
                    if rest[cursor] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    value.append(rest[cursor])
                    cursor += 1
                }
                cursor += 1
            } else if rest[cursor] == "\"" {
                cursor += 1
                while cursor < rest.count, rest[cursor] != "\"" {
                    value.append(rest[cursor])
                    cursor += 1
                }
                cursor += 1
            } else {
                while cursor < rest.count, rest[cursor] != ",", !rest[cursor].isNewline {
                    value.append(rest[cursor])
                    cursor += 1
                }
            }
            if !name.isEmpty {
                fields[name.lowercased()] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return Entry(key: key, fields: fields, raw: raw)
    }
}
