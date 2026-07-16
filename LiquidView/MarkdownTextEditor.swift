import SwiftUI
import AppKit

/// Markdown-aware editing view: heading lines (`# `, `## `, `### `) display
/// larger and bold as you type, while the underlying text stays plain
/// markdown. Wraps NSTextView so styling can be reapplied per keystroke.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
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
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.hideHeadingMarkers = hideHeadingMarkers
        context.coordinator.onReference = onReference
        context.coordinator.speakers = speakers
        context.coordinator.onLiftStatement = onLiftStatement
        context.coordinator.contextDoc = contextDoc
        context.coordinator.contextMenuItems = contextMenuItems
        context.coordinator.applyStyling()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        context.coordinator.onReference = onReference
        context.coordinator.speakers = speakers
        context.coordinator.onLiftStatement = onLiftStatement
        context.coordinator.contextDoc = contextDoc
        context.coordinator.contextMenuItems = contextMenuItems
        var needsRestyle = false
        if context.coordinator.hideHeadingMarkers != hideHeadingMarkers {
            context.coordinator.hideHeadingMarkers = hideHeadingMarkers
            needsRestyle = true
        }
        if textView.string != text {
            textView.string = text
            needsRestyle = true
        }
        if needsRestyle {
            context.coordinator.applyStyling()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?
        var hideHeadingMarkers = true
        var onReference: ((String, String) -> Void)?
        var speakers: [String] = []
        var onLiftStatement: ((String) -> Void)?
        var contextDoc: (() -> LiquidDoc)?
        var contextMenuItems: ((ContextTarget) -> [NSMenuItem])?
        /// The statement under the last right-click, held between building
        /// the menu and the menu item firing.
        private var pendingLiftStatement: String?

        init(text: Binding<String>) {
            self.text = text
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

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            applyStyling()
        }

        /// Structured pastes become citations: Reader's "Copy Quote"/"Copy
        /// Cite" becomes a healed quotation with a linked attribution, and
        /// BibTeX entries become citation lines. Everything else passes
        /// through untouched.
        func textView(_ textView: NSTextView,
                      shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacementString else { return true }
            let replacement: String?
            if let quote = ReaderQuoteParser.parse(replacementString) {
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
            guard var transformed = replacement, !transformed.isEmpty else { return true }
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

        /// Restyles the whole document: body serif everywhere, with heading
        /// lines sized and bolded by their markdown prefix. Attribute-only
        /// changes, so selection and undo state stay put.
        func applyStyling() {
            guard let textView, let storage = textView.textStorage else { return }
            let string = storage.string as NSString
            let fullRange = NSRange(location: 0, length: string.length)

            storage.beginEditing()
            storage.setAttributes([
                .font: Self.bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: Self.paragraphStyle,
            ], range: fullRange)

            string.enumerateSubstrings(in: fullRange, options: [.byParagraphs]) { substring, range, _, _ in
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
                    return
                }
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
            storage.endEditing()
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
    }
}
