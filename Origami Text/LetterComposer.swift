import SwiftUI
import UIKit

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
    @State private var namingAttention = false
    @State private var typedAttention = ""
    @State private var namingOnBehalf = false
    @State private var typedOnBehalf = ""
    @State private var choosingDate = false
    @State private var confirmingDiscard = false
    @State private var seeded = false
    @FocusState private var titleFocused: Bool

    private var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespaces).isEmpty
            && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $title)
                    .font(.system(size: 24, design: .serif))
                    .focused($titleFocused)
                if let linkedTitle = seed.linkedTitle, let rel = seed.link?.rel,
                   let relation = DocumentRelation.from(rel: rel), let label = relation.bylineLabel {
                    Text("\(label) “\(linkedTitle)” — the connection travels with the letter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bylineBar
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
            .alert("For the Attention Of", isPresented: $namingAttention) {
                TextField("Name", text: $typedAttention)
                Button("Add") { addAttention(typedAttention) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("On Behalf Of", isPresented: $namingOnBehalf) {
                TextField("Name", text: $typedOnBehalf)
                Button("Set") {
                    let trimmed = typedOnBehalf.trimmingCharacters(in: .whitespaces)
                    onBehalfOf = trimmed.isEmpty ? nil : trimmed
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The author remains \(model.authorName); the letter declares whose words it carries.")
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
                    }
                } else {
                    Menu(model.authorName) {
                        Button("On Behalf Of…") {
                            typedOnBehalf = ""
                            namingOnBehalf = true
                        }
                    }
                }
                Text("·")
                Button {
                    choosingDate = true
                } label: {
                    Text(date?.displayText ?? Date.now.formatted(date: .abbreviated, time: .omitted))
                }
                Text("·")
                Menu("Attention of") {
                    ForEach(model.knownNames, id: \.self) { name in
                        Button(name) { addAttention(name) }
                    }
                    if !model.knownNames.isEmpty { Divider() }
                    Button("New…") {
                        typedAttention = ""
                        namingAttention = true
                    }
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

    private func addAttention(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !attention.contains(trimmed) else { return }
        attention.append(trimmed)
    }

    private func publish() {
        let published = model.publishLetter(
            title: title,
            bodyText: bodyText,
            attention: attention,
            onBehalfOf: onBehalfOf,
            date: date,
            extraLinks: seed.link.map { [$0] } ?? [],
            references: references)
        if published != nil { dismiss() }
        // On failure the composer stays open; the reason is in
        // model.lastError, shown by the home view's alert after dismiss —
        // so surface it here too.
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
            var location = 0
            while location < nsText.length {
                let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
                let line = nsText.substring(with: lineRange)
                if let font = Self.headingFont(for: line) {
                    storage.addAttribute(.font, value: font, range: lineRange)
                }
                location = NSMaxRange(lineRange)
                if location == 0 { break }
            }
            storage.endEditing()
            textView.selectedRange = selected
        }

        private static func headingFont(for line: String) -> UIFont? {
            let size: CGFloat
            let weight: UIFont.Weight
            if line.hasPrefix("### ") { size = 19; weight = .semibold }
            else if line.hasPrefix("## ") { size = 22; weight = .bold }
            else if line.hasPrefix("# ") { size = 25; weight = .bold }
            else { return nil }
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
