import SwiftUI
import AppKit

/// Markdown-aware editing view: heading lines (`# `, `## `, `### `) display
/// larger and bold as you type, and inline emphasis (`**bold**`, `*italic*`,
/// `***both***`, and the `_` forms) renders with the words styled and the
/// markers hidden — while the underlying text stays plain markdown. Wraps
/// NSTextView so styling can be reapplied per keystroke.
/// An image inserted into the editor's text for an `![alt](asset:id)`
/// marker. It carries the exact marker so the body serializes back to plain
/// markdown — the text stays the source of truth.
final class MarkdownImageAttachment: NSTextAttachment {
    let marker: String
    init(marker: String, image: NSImage) {
        self.marker = marker
        super.init(data: nil, ofType: nil)
        self.image = image
        // Scale wide images down to the text measure; keep aspect.
        let maxWidth: CGFloat = 460
        let size = image.size
        let scale = size.width > maxWidth && size.width > 0 ? maxWidth / size.width : 1
        bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
    }
    required init?(coder: NSCoder) { marker = ""; super.init(coder: coder) }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Resolved images for `asset:` markers, keyed by asset id. Markers
    /// whose image is here render inline; the rest stay as text.
    var images: [String: NSImage] = [:]
    var hideHeadingMarkers = true
    /// Called when a pasted citation carries a full record:
    /// (derived address, BibTeX).
    var onReference: ((String, String) -> Void)?
    /// The transcript's known speakers. When the clicked paragraph opens
    /// with one of these names ("Tom Haymes: …"), the context menu offers
    /// lifting that statement into a new document.
    var speakers: [String] = []
    /// Called with the clicked statement's full paragraph text when the
    /// user chooses "Lift to New".
    var onLiftStatement: ((String) -> Void)?
    /// The draft as it stands, for selection actions that cite it.
    var contextDoc: (() -> LiquidDoc)?
    /// Renders the shared context actions for a target (the view owning
    /// the model supplies this; the editor only names what was clicked).
    var contextMenuItems: ((ContextTarget) -> [NSMenuItem])?
    /// Set true to hand the keyboard to the body text; flips back once
    /// taken — how Tab in the title lands here.
    var claimFocus: Binding<Bool>? = nil
    /// Set to a 1-based paragraph number (the Nth non-empty line — the
    /// same numbering parseBody assigns ids by) to scroll there and
    /// flash it; resets once done. How a summary note points back at
    /// the statement that produced it.
    var revealParagraph: Binding<Int?>? = nil

    /// The menu is owned at the view level: on current SDKs the text
    /// system can build its menu without consulting the delegate hook, so
    /// the override is the reliable seam.
    final class EditorNSTextView: NSTextView, NSMenuDelegate {
        var augmentMenu: ((NSMenu, Int) -> Void)?

        /// The editor's menu is ours plus exactly one system concern:
        /// spelling — suggestions for the misspelled word under the
        /// pointer, and the spelling controls. Everything else is
        /// suppressed; keyboard shortcuts carry the basics.
        override func menu(for event: NSEvent) -> NSMenu? {
            let system = super.menu(for: event)
            let menu = NSMenu()
            // AppKit injects Services, AutoFill, and similar into context
            // menus on its own; refuse plug-ins and gate the rest at open.
            menu.allowsContextMenuPlugIns = false
            menu.delegate = self
            let point = convert(event.locationInWindow, from: nil)
            augmentMenu?(menu, characterIndexForInsertion(at: point))
            if let system {
                let spelling = system.items.filter(Self.isSpellingItem)
                if !spelling.isEmpty {
                    if !menu.items.isEmpty { menu.addItem(.separator()) }
                    for item in spelling {
                        system.removeItem(item)   // an item belongs to one menu
                        menu.addItem(item)
                    }
                }
            }
            for item in menu.items { item.tag = Self.ownedItemTag }
            return menu
        }

        /// Anything in the menu we did not put there was injected by the
        /// system after we returned it; it goes.
        static let ownedItemTag = 0x0716
        func menuNeedsUpdate(_ menu: NSMenu) {
            for item in menu.items where item.tag != Self.ownedItemTag {
                menu.removeItem(item)
            }
        }

        /// Spelling suggestions and controls, identified by their actions
        /// rather than their localized titles.
        private static func isSpellingItem(_ item: NSMenuItem) -> Bool {
            let spellingSelectors: Set<String> = [
                "changeSpelling:", "ignoreSpelling:", "learnSpelling:",
                "unlearnSpelling:", "showGuessPanel:", "checkSpelling:",
            ]
            func matches(_ menuItem: NSMenuItem) -> Bool {
                guard let action = menuItem.action else { return false }
                let name = NSStringFromSelector(action)
                return spellingSelectors.contains(name)
                    || name.hasPrefix("toggleAutomaticSpellingCorrection")
                    || name.hasPrefix("toggleContinuousSpellChecking")
                    || name.hasPrefix("toggleGrammarChecking")
            }
            if matches(item) { return true }
            if let submenu = item.submenu {
                return submenu.items.contains(where: matches)
            }
            return false
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorNSTextView(usingTextLayoutManager: false)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.augmentMenu = { [weak coordinator = context.coordinator] menu, charIndex in
            coordinator?.augment(menu, in: textView, at: charIndex)
        }
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = true          // styling is ours; pasted styles get normalized
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 12)
        context.coordinator.textView = textView
        context.coordinator.images = images
        context.coordinator.hideHeadingMarkers = hideHeadingMarkers
        context.coordinator.onReference = onReference
        context.coordinator.speakers = speakers
        context.coordinator.onLiftStatement = onLiftStatement
        context.coordinator.contextDoc = contextDoc
        context.coordinator.contextMenuItems = contextMenuItems
        context.coordinator.setContent(text)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        context.coordinator.images = images
        context.coordinator.onReference = onReference
        context.coordinator.speakers = speakers
        context.coordinator.onLiftStatement = onLiftStatement
        context.coordinator.contextDoc = contextDoc
        context.coordinator.contextMenuItems = contextMenuItems
        let headingMarkerToggleChanged = context.coordinator.hideHeadingMarkers != hideHeadingMarkers
        context.coordinator.hideHeadingMarkers = hideHeadingMarkers
        // Rebuild only when the model's markdown actually differs from what
        // the editor holds (serialized back from any inline images) — so a
        // SwiftUI refresh never clobbers the caret or the user's edits.
        if context.coordinator.serializedMarkdown() != text {
            context.coordinator.setContent(text)
        } else if headingMarkerToggleChanged {
            context.coordinator.applyStyling()
        }
        if claimFocus?.wrappedValue == true {
            textView.window?.makeFirstResponder(textView)
            // Reset outside the update pass.
            let claimFocus = claimFocus
            Task { @MainActor in claimFocus?.wrappedValue = false }
        }
        if let target = revealParagraph?.wrappedValue {
            context.coordinator.reveal(nonEmptyLine: target)
            let revealParagraph = revealParagraph
            Task { @MainActor in revealParagraph?.wrappedValue = nil }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?
        var images: [String: NSImage] = [:]
        var hideHeadingMarkers = true
        var onReference: ((String, String) -> Void)?
        var speakers: [String] = []
        var onLiftStatement: ((String) -> Void)?
        var contextDoc: (() -> LiquidDoc)?
        var contextMenuItems: ((ContextTarget) -> [NSMenuItem])?
        /// The statement under the last right-click, held between building
        /// the menu and the menu item firing.
        private var pendingLiftStatement: String?
        /// Where the last accepted edit landed, post-change — so restyling
        /// touches only the paragraphs it could have altered instead of
        /// the whole letter on every keystroke.
        private var pendingEditedRange: NSRange?

        init(text: Binding<String>) {
            self.text = text
        }

        // MARK: - Inline images ↔ markdown

        /// Replaces the editor's contents with `markdown`, rendering each
        /// `![alt](asset:id)` line whose image is known as an inline image
        /// (the rest stays text), then styles it.
        func setContent(_ markdown: String) {
            guard let storage = textView?.textStorage else { return }
            storage.setAttributedString(attributedContent(from: markdown))
            applyStyling()
        }

        private func attributedContent(from markdown: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let lines = markdown.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if let reference = LiquidDoc.imageReference(in: line),
                   let image = images[reference.id] {
                    let attachment = MarkdownImageAttachment(marker: line, image: image)
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    result.append(NSAttributedString(string: line))
                }
                if index < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n"))
                }
            }
            return result
        }

        /// The current contents as markdown — inline images turned back into
        /// their `![alt](asset:id)` markers. This is what the body binding
        /// carries, so images never corrupt the source text.
        func serializedMarkdown() -> String {
            guard let storage = textView?.textStorage else { return text.wrappedValue }
            let nsString = storage.string as NSString
            var out = ""
            storage.enumerateAttribute(.attachment,
                                       in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let attachment = value as? MarkdownImageAttachment {
                    out += attachment.marker
                } else {
                    out += nsString.substring(with: range)
                }
            }
            return out
        }

        /// The hidden "# " marker of the paragraph containing `index`,
        /// when markers are hidden and the paragraph is a heading: from
        /// the first "#" through the following space — the same range
        /// the styling collapses to nothing.
        private func hiddenMarkerRange(containing index: Int, in string: NSString) -> NSRange? {
            guard hideHeadingMarkers, string.length > 0 else { return nil }
            let paragraph = string.paragraphRange(
                for: NSRange(location: min(index, string.length), length: 0))
            var cursor = paragraph.location
            let end = NSMaxRange(paragraph)
            while cursor < end,
                  string.character(at: cursor) == 0x20 || string.character(at: cursor) == 0x09 {
                cursor += 1
            }
            var level = 0
            while cursor + level < end, level < 3, string.character(at: cursor + level) == 0x23 {
                level += 1
            }
            guard level > 0, cursor + level < end,
                  string.character(at: cursor + level) == 0x20 else { return nil }
            return NSRange(location: cursor, length: level + 1)
        }

        /// One parsed emphasis run's geometry, in document coordinates.
        private struct EmphasisRun {
            let match: NSRange     // the whole `**words**`
            let content: NSRange   // just the words
            let opening: NSRange
            let closing: NSRange
        }

        /// The hidden emphasis-marker pairs of the paragraph containing
        /// `index` — the same matches the styling hides, so the caret and
        /// deletion handling below agree exactly with what is invisible.
        private func emphasisRuns(inParagraphContaining index: Int, in string: NSString) -> [EmphasisRun] {
            guard hideHeadingMarkers, string.length > 0 else { return [] }
            let paragraph = string.paragraphRange(
                for: NSRange(location: min(index, string.length), length: 0))
            let text = string.substring(with: paragraph)
            guard text.contains("*") || text.contains("_") else { return [] }
            var runs: [EmphasisRun] = []
            let full = NSRange(location: 0, length: (text as NSString).length)
            for pattern in Self.emphasisPatterns {
                for match in pattern.matches(in: text, range: full) {
                    let marker = match.range(at: 1)
                    let content = match.range(at: 2)
                    let offset = paragraph.location
                    runs.append(EmphasisRun(
                        match: NSRange(location: offset + match.range.location,
                                       length: match.range.length),
                        content: NSRange(location: offset + content.location,
                                         length: content.length),
                        opening: NSRange(location: offset + marker.location,
                                         length: marker.length),
                        closing: NSRange(location: offset + NSMaxRange(match.range) - marker.length,
                                         length: marker.length)))
                }
            }
            return runs
        }

        /// The caret never rests inside a hidden marker — its characters
        /// are invisible, so a caret there looks frozen and deletions
        /// there seem to do nothing. A caret headed in snaps out: one
        /// step back from the heading's visible start crosses to the
        /// previous line's end in a single press; everything else lands
        /// at the start of the heading's words.
        func textView(_ textView: NSTextView,
                      willChangeSelectionFromCharacterRanges oldRanges: [NSValue],
                      toCharacterRanges newRanges: [NSValue]) -> [NSValue] {
            guard hideHeadingMarkers else { return newRanges }
            let string = textView.string as NSString
            let oldLocation = oldRanges.first?.rangeValue.location
            return newRanges.map { value in
                var range = value.rangeValue
                guard range.length == 0 else { return value }
                if let marker = hiddenMarkerRange(containing: range.location, in: string),
                   range.location >= marker.location,
                   range.location < NSMaxRange(marker) {
                    let markerEnd = NSMaxRange(marker)
                    if range.location == markerEnd - 1, oldLocation == markerEnd,
                       marker.location > 0 {
                        // Arrow-left from the heading's visible start: past
                        // the whole marker to the previous line's end.
                        range.location = string.paragraphRange(
                            for: NSRange(location: marker.location, length: 0)).location - 1
                    } else {
                        range.location = markerEnd
                    }
                    return NSValue(range: range)
                }
                // Hidden emphasis markers: a caret strictly inside one snaps
                // to the edge it was headed for — its characters are
                // invisible, so both edges look the same and a caret between
                // them would seem frozen.
                for run in emphasisRuns(inParagraphContaining: range.location, in: string) {
                    for marker in [run.opening, run.closing]
                    where range.location > marker.location && range.location < NSMaxRange(marker) {
                        let movingLeft = (oldLocation ?? 0) >= NSMaxRange(marker)
                        range.location = movingLeft ? marker.location : NSMaxRange(marker)
                        return NSValue(range: range)
                    }
                }
                return value
            }
        }

        /// The editor's context menu, with "Lift to New" on transcript
        /// statements: right-clicking a paragraph that opens with a known
        /// speaker's name offers making their words a document of their own.
        func augment(_ menu: NSMenu, in view: NSTextView, at charIndex: Int) {
            // A click inside the selection: the shared selection actions
            // lead the menu (Copy as Quote, and whatever the selected
            // words turn out to be — a known name, an address).
            let selectedRange = view.selectedRange()
            if let contextMenuItems, selectedRange.length > 0,
               NSLocationInRange(charIndex, selectedRange) {
                let selectedText = (view.string as NSString).substring(with: selectedRange)
                let shared = contextMenuItems(.selection(text: selectedText, doc: contextDoc?()))
                for (offset, item) in shared.enumerated() {
                    menu.insertItem(item, at: offset)
                }
                if !shared.isEmpty {
                    menu.insertItem(.separator(), at: shared.count)
                }
            }
            guard onLiftStatement != nil, !speakers.isEmpty else { return }
            let string = view.string as NSString
            guard string.length > 0 else { return }
            let location = min(charIndex, string.length - 1)
            let paragraph = string
                .substring(with: string.paragraphRange(for: NSRange(location: location, length: 0)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let speaker = speakers.first(where: { paragraph.hasPrefix("\($0):") })
            else { return }
            pendingLiftStatement = paragraph
            let item = NSMenuItem(title: "Lift to New — statement by \(speaker)",
                                  action: #selector(liftPendingStatement), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        @objc private func liftPendingStatement() {
            if let statement = pendingLiftStatement {
                onLiftStatement?(statement)
            }
            pendingLiftStatement = nil
        }

        /// Scrolls to the Nth non-empty line — paragraph pN in the saved
        /// document — and flashes it with the system's find indicator.
        func reveal(nonEmptyLine target: Int) {
            guard let textView, target > 0 else { return }
            let string = textView.string as NSString
            var count = 0
            var location = 0
            while location < string.length {
                let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
                let line = string.substring(with: lineRange)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    count += 1
                    if count == target {
                        textView.scrollRangeToVisible(lineRange)
                        textView.showFindIndicator(for: lineRange)
                        return
                    }
                }
                let next = NSMaxRange(lineRange)
                if next <= location { break }
                location = next
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Serialize so inline images become their markers again, not the
            // attachment placeholder character.
            text.wrappedValue = serializedMarkdown()
            let edited = pendingEditedRange
            pendingEditedRange = nil
            // Never restyle mid-composition: dead keys and CJK input hold
            // marked text whose attributes a restyle would wipe. The
            // change that ends the composition styles the result.
            guard !textView.hasMarkedText() else { return }
            applyStyling(in: edited)
        }

        /// Structured pastes become citations: Reader's "Copy Quote"/"Copy
        /// Cite" becomes a healed quotation with a linked attribution, and
        /// BibTeX entries become citation lines. Everything else passes
        /// through untouched.
        func textView(_ textView: NSTextView,
                      shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            // Deleting into a hidden heading marker takes the whole
            // marker in one press: backspace at the visible start of a
            // heading unmakes the heading, instead of eating invisible
            // characters one by one with nothing to show for it.
            if replacementString.isEmpty, hideHeadingMarkers, affectedRange.length > 0 {
                let string = textView.string as NSString
                if let marker = hiddenMarkerRange(containing: affectedRange.location, in: string),
                   NSIntersectionRange(affectedRange, marker).length > 0,
                   !(affectedRange.location <= marker.location
                     && NSMaxRange(affectedRange) >= NSMaxRange(marker)) {
                    textView.insertText("", replacementRange: NSUnionRange(affectedRange, marker))
                    return false
                }
                // Deleting into a hidden emphasis marker removes the pair in
                // one press: the words stay, unemphasized — instead of eating
                // invisible asterisks with nothing to show for it.
                for run in emphasisRuns(inParagraphContaining: affectedRange.location, in: string) {
                    let hitsMarker = NSIntersectionRange(affectedRange, run.opening).length > 0
                        || NSIntersectionRange(affectedRange, run.closing).length > 0
                    let coversWholeRun = affectedRange.location <= run.match.location
                        && NSMaxRange(affectedRange) >= NSMaxRange(run.match)
                    if hitsMarker, !coversWholeRun {
                        textView.insertText(string.substring(with: run.content),
                                            replacementRange: run.match)
                        return false
                    }
                }
            }
            let replacement: String?
            // A "Copy as Quote" citation on the clipboard: take the richest
            // flavour (private JSON, else the HTML hyperlink) and insert the
            // native bracketed form so it becomes a span-scoped cites link.
            if let citation = CitationClipboard.read(matchingPlainText: replacementString) {
                replacement = citation.insertionText
                if let bibtex = citation.bibtex, !bibtex.isEmpty {
                    onReference?(citation.address, bibtex)
                }
            } else if let quote = ReaderQuoteParser.parse(replacementString) {
                replacement = quote.draftText
                if let id = quote.derivedID, let bibtex = quote.synthesizedBibTeX {
                    onReference?(id, bibtex)
                }
            } else {
                let entries = BibTeXParser.parse(replacementString)
                replacement = entries.isEmpty
                    ? nil
                    : entries.map(\.citationText).joined(separator: "\n\n")
                for entry in entries {
                    if let id = entry.derivedID {
                        onReference?(id, entry.raw)
                    }
                }
            }
            guard var transformed = replacement, !transformed.isEmpty else {
                // An ordinary edit: remember where it lands, so the
                // restyle that follows touches only those paragraphs.
                pendingEditedRange = NSRange(location: affectedRange.location,
                                             length: (replacementString as NSString).length)
                return true
            }
            if affectedRange.location > 0 {
                let existing = textView.string as NSString
                let previous = existing.character(at: affectedRange.location - 1)
                if let scalar = Unicode.Scalar(previous), !CharacterSet.newlines.contains(scalar) {
                    transformed = "\n\n" + transformed
                }
            }
            textView.insertText(transformed, replacementRange: affectedRange)
            return false
        }

        /// Restyles the edited paragraphs — or, given no range, the whole
        /// document: body serif everywhere, with heading lines sized and
        /// bolded by their markdown prefix. Attribute-only changes, so
        /// selection and undo state stay put; per-paragraph scope, so a
        /// keystroke never pays for the whole letter.
        func applyStyling(in editedRange: NSRange? = nil) {
            guard let textView, let storage = textView.textStorage else { return }
            let string = storage.string as NSString
            let fullRange = NSRange(location: 0, length: string.length)
            // Heading styling is a per-paragraph decision, so restyling
            // the paragraphs the edit touched is always complete. The
            // range is clamped by hand: a zero-length edit at the very
            // end (a deletion there) must keep its position.
            let target = editedRange.map { edited in
                let location = min(edited.location, string.length)
                let length = min(edited.length, string.length - location)
                return string.paragraphRange(for: NSRange(location: location, length: length))
            } ?? fullRange

            storage.beginEditing()
            string.enumerateSubstrings(in: target, options: [.byParagraphs]) { substring, range, _, _ in
                // Leave inline-image paragraphs untouched — a bulk restyle
                // would strip the attachment and lose the picture.
                if self.hasAttachment(in: range, storage: storage) { return }
                storage.setAttributes([
                    .font: Self.bodyFont,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: Self.paragraphStyle,
                ], range: range)
                guard let substring else { return }
                let trimmed = substring.trimmingCharacters(in: .whitespaces)
                let level: Int
                if trimmed.hasPrefix("### ") {
                    level = 3
                } else if trimmed.hasPrefix("## ") {
                    level = 2
                } else if trimmed.hasPrefix("# ") {
                    level = 1
                } else {
                    level = 0
                }
                if level > 0 {
                    storage.addAttribute(.font, value: Self.headingFonts[level - 1], range: range)

                    // The "# " marker itself: invisible when hidden, dimmed when shown.
                    var leadingWhitespace = 0
                    for scalar in substring.unicodeScalars {
                        if scalar == " " || scalar == "\t" { leadingWhitespace += 1 } else { break }
                    }
                    let markerRange = NSRange(location: range.location + leadingWhitespace, length: level + 1)
                    if self.hideHeadingMarkers {
                        storage.addAttributes([
                            .font: Self.hiddenMarkerFont,
                            .foregroundColor: NSColor.clear,
                        ], range: markerRange)
                    } else {
                        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: markerRange)
                    }
                }
                self.applyInlineEmphasis(to: substring, at: range, storage: storage)
            }
            storage.endEditing()
        }

        // Inline emphasis, both markdown spellings: a run of 1–3 markers
        // hugging the words (no space inside), closed by the same run.
        // Word and Markdown imports arrive in the `*` form; hand-written
        // markdown may use `_`, which must not fire inside snake_case.
        private static let emphasisPatterns: [NSRegularExpression] = [
            "(?<!\\*)(\\*{1,3})(?![\\s*])(.+?)(?<!\\s)\\1(?!\\*)",
            "(?<![\\w_])(_{1,3})(?![\\s_])(.+?)(?<!\\s)\\1(?![\\w_])",
        ].compactMap { try? NSRegularExpression(pattern: $0) }

        /// Renders inline markdown emphasis in one paragraph: the marked
        /// words get the bold/italic variant of whatever font they already
        /// wear (so emphasis inside a heading keeps the heading size, and
        /// `_nested_` inside `**bold**` compounds), and the markers vanish
        /// once parsed — invisible like the heading markers, dimmed when
        /// markers are shown. Attribute-only, like the rest of the styling:
        /// the text remains plain markdown.
        private func applyInlineEmphasis(to paragraph: String, at range: NSRange,
                                         storage: NSTextStorage) {
            guard paragraph.contains("*") || paragraph.contains("_") else { return }
            let ns = paragraph as NSString
            let full = NSRange(location: 0, length: ns.length)
            for pattern in Self.emphasisPatterns {
                for match in pattern.matches(in: paragraph, range: full) {
                    let marker = match.range(at: 1)
                    let content = match.range(at: 2)
                    let bold = marker.length >= 2
                    let italic = marker.length == 1 || marker.length == 3
                    let contentRange = NSRange(location: range.location + content.location,
                                               length: content.length)
                    let existing = storage.attribute(.font, at: contentRange.location,
                                                     effectiveRange: nil) as? NSFont ?? Self.bodyFont
                    storage.addAttribute(.font,
                                         value: Self.emphasisFont(from: existing, bold: bold, italic: italic),
                                         range: contentRange)
                    for markerRange in [
                        NSRange(location: range.location + marker.location, length: marker.length),
                        NSRange(location: range.location + NSMaxRange(match.range) - marker.length,
                                length: marker.length),
                    ] {
                        if self.hideHeadingMarkers {
                            storage.addAttributes([
                                .font: Self.hiddenMarkerFont,
                                .foregroundColor: NSColor.clear,
                            ], range: markerRange)
                        } else {
                            storage.addAttribute(.foregroundColor,
                                                 value: NSColor.tertiaryLabelColor, range: markerRange)
                        }
                    }
                }
            }
        }

        /// Whether `range` contains a text attachment (an inline image).
        private func hasAttachment(in range: NSRange, storage: NSTextStorage) -> Bool {
            guard range.length > 0 else { return false }
            var found = false
            storage.enumerateAttribute(.attachment, in: range) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }

        // MARK: - Typography (matches the reading view)

        private static let bodyFont = serifFont(size: 17, weight: .regular)
        private static let headingFonts = [
            serifFont(size: 28, weight: .bold),
            serifFont(size: 23, weight: .bold),
            serifFont(size: 19, weight: .bold),
        ]

        // Near-zero size collapses the marker's width so hidden markers
        // don't leave a gap in front of the heading.
        private static let hiddenMarkerFont = NSFont.systemFont(ofSize: 0.1)

        private static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = 8
            return style
        }()

        private static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.serif),
               let serif = NSFont(descriptor: descriptor, size: size) {
                return serif
            }
            return base
        }

        /// `base` with bold/italic traits added — same face, same size.
        private static func emphasisFont(from base: NSFont, bold: Bool, italic: Bool) -> NSFont {
            var traits = base.fontDescriptor.symbolicTraits
            if bold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
            return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
        }
    }
}
